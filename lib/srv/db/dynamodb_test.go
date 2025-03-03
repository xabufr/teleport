/*
Copyright 2022 Gravitational, Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package db

import (
	"context"
	"crypto/tls"
	"net"
	"net/http"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/client"
	"github.com/aws/aws-sdk-go/aws/credentials"
	awsdynamodb "github.com/aws/aws-sdk-go/service/dynamodb"
	"github.com/stretchr/testify/require"

	"github.com/gravitational/teleport/api/types"
	"github.com/gravitational/teleport/lib/defaults"
	libevents "github.com/gravitational/teleport/lib/events"
	"github.com/gravitational/teleport/lib/srv/db/common"
	"github.com/gravitational/teleport/lib/srv/db/dynamodb"
)

func registerTestDynamoDBEngine() {
	// Override DynamoDB engine that is used normally with the test one
	// with custom HTTP client.
	common.RegisterEngine(newTestDynamoDBEngine, defaults.ProtocolDynamoDB)
}

func newTestDynamoDBEngine(ec common.EngineConfig) common.Engine {
	return &dynamodb.Engine{
		EngineConfig:  ec,
		RoundTrippers: make(map[string]http.RoundTripper),
		// inject mock AWS credentials.
		GetSigningCredsFn: staticAWSCredentials,
	}
}

func staticAWSCredentials(client.ConfigProvider, time.Time, string, string, string) *credentials.Credentials {
	return credentials.NewStaticCredentials("AKIDl", "SECRET", "SESSION")
}

func TestAccessDynamoDB(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	mockTables := []string{"table-one", "table-two"}
	testCtx := setupTestContext(ctx, t,
		withDynamoDB("DynamoDB"))
	go testCtx.startHandlingConnections()

	tests := []struct {
		desc         string
		user         string
		role         string
		allowDbUsers []string
		dbUser       string
		wantErrMsg   string
	}{
		{
			desc:         "has access to all database names and users",
			user:         "alice",
			role:         "admin",
			allowDbUsers: []string{types.Wildcard},
			dbUser:       "alice",
		},
		{
			desc:         "access allowed to specific user",
			user:         "alice",
			role:         "admin",
			allowDbUsers: []string{"alice"},
			dbUser:       "alice",
		},
		{
			desc:         "has access to nothing",
			user:         "alice",
			role:         "admin",
			allowDbUsers: []string{},
			dbUser:       "alice",
			wantErrMsg:   "access to db denied",
		},
		{
			desc:         "no access to users",
			user:         "alice",
			role:         "admin",
			allowDbUsers: []string{},
			dbUser:       "alice",
			wantErrMsg:   "access to db denied",
		},
		{
			desc:         "access denied to specific user",
			user:         "alice",
			role:         "admin",
			allowDbUsers: []string{"alice"},
			dbUser:       "bob",
			wantErrMsg:   "access to db denied",
		},
	}

	for _, test := range tests {
		t.Run(test.desc, func(t *testing.T) {
			// Create user/role with the requested permissions.
			testCtx.createUserAndRole(ctx, t, test.user, test.role, test.allowDbUsers, []string{} /*allow DB names*/)

			// Try to connect to the database as this user.
			clt, lp, err := testCtx.dynamodbClient(ctx, test.user, "DynamoDB", test.dbUser)
			t.Cleanup(func() {
				if lp != nil {
					lp.Close()
				}
			})
			require.NoError(t, err)

			// Execute a dynamodb query.
			out, err := clt.ListTables(&awsdynamodb.ListTablesInput{})
			if test.wantErrMsg != "" {
				require.Error(t, err)
				require.ErrorContains(t, err, test.wantErrMsg)
				return
			}
			require.NoError(t, err)
			require.ElementsMatch(t, mockTables, aws.StringValueSlice(out.TableNames))
		})
	}
}

func TestAuditDynamoDB(t *testing.T) {
	ctx := context.Background()
	testCtx := setupTestContext(ctx, t,
		withDynamoDB("DynamoDB"))
	go testCtx.startHandlingConnections()

	testCtx.createUserAndRole(ctx, t, "alice", "admin", []string{"admin"}, []string{types.Wildcard})

	clientCtx, cancel := context.WithCancel(ctx)
	t.Run("access denied", func(t *testing.T) {
		// Try to connect to the database as this user.
		clt, lp, err := testCtx.dynamodbClient(clientCtx, "alice", "DynamoDB", "notadmin")
		t.Cleanup(func() {
			if lp != nil {
				lp.Close()
			}
		})
		require.NoError(t, err)

		// Execute a dynamodb query.
		_, err = clt.ListTables(&awsdynamodb.ListTablesInput{})
		require.Error(t, err)
		require.ErrorContains(t, err, "access to db denied")
		requireEvent(t, testCtx, libevents.DatabaseSessionStartFailureCode)
	})

	// HTTP request should trigger successful session start/end events and emit an audit event for the request.
	clt, lp, err := testCtx.dynamodbClient(clientCtx, "alice", "DynamoDB", "admin")
	t.Cleanup(func() {
		cancel()
		if lp != nil {
			lp.Close()
		}
	})
	require.NoError(t, err)

	t.Run("session starts and emits a request event", func(t *testing.T) {
		_, err := clt.ListTables(&awsdynamodb.ListTablesInput{})
		require.NoError(t, err)
		requireEvent(t, testCtx, libevents.DatabaseSessionStartCode)
		requireEvent(t, testCtx, libevents.DynamoDBRequestCode)
	})

	t.Run("session ends when client closes the connection", func(t *testing.T) {
		clt.Config.HTTPClient.CloseIdleConnections()
		requireEvent(t, testCtx, libevents.DatabaseSessionEndCode)
	})

	t.Run("session ends when local proxy closes the connection", func(t *testing.T) {
		// closing local proxy and canceling the context used to start it should trigger session end event.
		// without this cancel, the session will not end until the smaller of client_idle_timeout or the testCtx closes.
		_, err := clt.ListTables(&awsdynamodb.ListTablesInput{})
		require.NoError(t, err)
		requireEvent(t, testCtx, libevents.DatabaseSessionStartCode)
		requireEvent(t, testCtx, libevents.DynamoDBRequestCode)
		cancel()
		lp.Close()
		requireEvent(t, testCtx, libevents.DatabaseSessionEndCode)
	})
}

func withDynamoDB(name string, opts ...dynamodb.TestServerOption) withDatabaseOption {
	return func(t *testing.T, _ context.Context, testCtx *testContext) types.Database {
		config := common.TestServerConfig{
			Name:       name,
			AuthClient: testCtx.authClient,
			ClientAuth: tls.NoClientCert, // DynamoDB is cloud hosted and does not use mTLS.
		}
		server, err := dynamodb.NewTestServer(config, opts...)
		require.NoError(t, err)
		go server.Serve()
		t.Cleanup(func() { server.Close() })

		require.Len(t, testCtx.databaseCA.GetActiveKeys().TLS, 1)
		ca := string(testCtx.databaseCA.GetActiveKeys().TLS[0].Cert)
		database, err := types.NewDatabaseV3(types.Metadata{
			Name: name,
		}, types.DatabaseSpecV3{
			Protocol:      defaults.ProtocolDynamoDB,
			URI:           net.JoinHostPort("localhost", server.Port()),
			DynamicLabels: dynamicLabels,
			AWS: types.AWS{
				Region:    "us-west-1",
				AccountID: "12345",
			},
			TLS: types.DatabaseTLS{
				// Set CA, otherwise the engine will attempt to download and use the AWS CA.
				CACert: ca,
			},
		})
		require.NoError(t, err)

		testCtx.dynamodb[name] = testDynamoDB{
			db:       server,
			resource: database,
		}
		return database
	}
}
