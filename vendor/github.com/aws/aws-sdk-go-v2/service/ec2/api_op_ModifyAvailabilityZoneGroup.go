// Code generated by smithy-go-codegen DO NOT EDIT.

package ec2

import (
	"context"
	awsmiddleware "github.com/aws/aws-sdk-go-v2/aws/middleware"
	"github.com/aws/aws-sdk-go-v2/aws/signer/v4"
	"github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/smithy-go/middleware"
	smithyhttp "github.com/aws/smithy-go/transport/http"
)

// Changes the opt-in status of the Local Zone and Wavelength Zone group for your
// account. Use  DescribeAvailabilityZones
// (https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_DescribeAvailabilityZones.html)
// to view the value for GroupName.
func (c *Client) ModifyAvailabilityZoneGroup(ctx context.Context, params *ModifyAvailabilityZoneGroupInput, optFns ...func(*Options)) (*ModifyAvailabilityZoneGroupOutput, error) {
	if params == nil {
		params = &ModifyAvailabilityZoneGroupInput{}
	}

	result, metadata, err := c.invokeOperation(ctx, "ModifyAvailabilityZoneGroup", params, optFns, c.addOperationModifyAvailabilityZoneGroupMiddlewares)
	if err != nil {
		return nil, err
	}

	out := result.(*ModifyAvailabilityZoneGroupOutput)
	out.ResultMetadata = metadata
	return out, nil
}

type ModifyAvailabilityZoneGroupInput struct {

	// The name of the Availability Zone group, Local Zone group, or Wavelength Zone
	// group.
	//
	// This member is required.
	GroupName *string

	// Indicates whether you are opted in to the Local Zone group or Wavelength Zone
	// group. The only valid value is opted-in. You must contact AWS Support
	// (https://console.aws.amazon.com/support/home#/case/create%3FissueType=customer-service%26serviceCode=general-info%26getting-started%26categoryCode=using-aws%26services)
	// to opt out of a Local Zone group, or Wavelength Zone group.
	//
	// This member is required.
	OptInStatus types.ModifyAvailabilityZoneOptInStatus

	// Checks whether you have the required permissions for the action, without
	// actually making the request, and provides an error response. If you have the
	// required permissions, the error response is DryRunOperation. Otherwise, it is
	// UnauthorizedOperation.
	DryRun *bool

	noSmithyDocumentSerde
}

type ModifyAvailabilityZoneGroupOutput struct {

	// Is true if the request succeeds, and an error otherwise.
	Return *bool

	// Metadata pertaining to the operation's result.
	ResultMetadata middleware.Metadata

	noSmithyDocumentSerde
}

func (c *Client) addOperationModifyAvailabilityZoneGroupMiddlewares(stack *middleware.Stack, options Options) (err error) {
	err = stack.Serialize.Add(&awsEc2query_serializeOpModifyAvailabilityZoneGroup{}, middleware.After)
	if err != nil {
		return err
	}
	err = stack.Deserialize.Add(&awsEc2query_deserializeOpModifyAvailabilityZoneGroup{}, middleware.After)
	if err != nil {
		return err
	}
	if err = addSetLoggerMiddleware(stack, options); err != nil {
		return err
	}
	if err = awsmiddleware.AddClientRequestIDMiddleware(stack); err != nil {
		return err
	}
	if err = smithyhttp.AddComputeContentLengthMiddleware(stack); err != nil {
		return err
	}
	if err = addResolveEndpointMiddleware(stack, options); err != nil {
		return err
	}
	if err = v4.AddComputePayloadSHA256Middleware(stack); err != nil {
		return err
	}
	if err = addRetryMiddlewares(stack, options); err != nil {
		return err
	}
	if err = addHTTPSignerV4Middleware(stack, options); err != nil {
		return err
	}
	if err = awsmiddleware.AddRawResponseToMetadata(stack); err != nil {
		return err
	}
	if err = awsmiddleware.AddRecordResponseTiming(stack); err != nil {
		return err
	}
	if err = addClientUserAgent(stack); err != nil {
		return err
	}
	if err = smithyhttp.AddErrorCloseResponseBodyMiddleware(stack); err != nil {
		return err
	}
	if err = smithyhttp.AddCloseResponseBodyMiddleware(stack); err != nil {
		return err
	}
	if err = addOpModifyAvailabilityZoneGroupValidationMiddleware(stack); err != nil {
		return err
	}
	if err = stack.Initialize.Add(newServiceMetadataMiddleware_opModifyAvailabilityZoneGroup(options.Region), middleware.Before); err != nil {
		return err
	}
	if err = addRequestIDRetrieverMiddleware(stack); err != nil {
		return err
	}
	if err = addResponseErrorMiddleware(stack); err != nil {
		return err
	}
	if err = addRequestResponseLogging(stack, options); err != nil {
		return err
	}
	return nil
}

func newServiceMetadataMiddleware_opModifyAvailabilityZoneGroup(region string) *awsmiddleware.RegisterServiceMetadata {
	return &awsmiddleware.RegisterServiceMetadata{
		Region:        region,
		ServiceID:     ServiceID,
		SigningName:   "ec2",
		OperationName: "ModifyAvailabilityZoneGroup",
	}
}
