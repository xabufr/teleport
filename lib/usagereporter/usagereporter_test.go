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

package usagereporter

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/gravitational/trace"
	"github.com/jonboulle/clockwork"
	log "github.com/sirupsen/logrus"
	"github.com/stretchr/testify/require"

	"github.com/gravitational/teleport"
)

const (
	testMinBatchSize  = 3
	testMaxBatchSize  = 5
	testMaxBufferSize = 10
	testRetryAttempts = 2
	testSubmitDelay   = time.Second * 1
	testMaxBatchAge   = time.Second * 5
)

type TestEvent struct {
	count string
}

// newTestSubmitter creates a submitter that reports batches to a channel.
func newTestSubmitter(size int) (SubmitFunc[TestEvent], chan []*SubmittedEvent[TestEvent]) {
	ch := make(chan []*SubmittedEvent[TestEvent], size)

	return func(reporter *UsageReporter[TestEvent], batch []*SubmittedEvent[TestEvent]) ([]*SubmittedEvent[TestEvent], error) {
		ch <- batch
		return nil, nil
	}, ch
}

// newFailingSubmitter creates a submitter function that always reports batches
// as failed. The current batch of events is written to the channel as usual
// for inspection.
func newFailingSubmitter(size int) (SubmitFunc[TestEvent], chan []*SubmittedEvent[TestEvent]) {
	ch := make(chan []*SubmittedEvent[TestEvent], size)

	return func(reporter *UsageReporter[TestEvent], batch []*SubmittedEvent[TestEvent]) ([]*SubmittedEvent[TestEvent], error) {
		ch <- batch
		return batch, trace.BadParameter("testing error")
	}, ch
}

// newTestingUsageReporter creates a new usage reporter that can be used in
// tests.
func newTestingUsageReporter(
	clock clockwork.FakeClock, submitClock clockwork.FakeClock,
	submitter SubmitFunc[TestEvent],
) (*UsageReporter[TestEvent], context.CancelFunc, chan struct{}) {
	ctx, cancel := context.WithCancel(context.Background())

	l := log.WithFields(log.Fields{
		trace.Component: teleport.Component(teleport.ComponentUsageReporting),
	})

	// Make a receiver callback. We'll use this channel to coordinate event
	// receipts, since otherwise we'll be racing the clock.
	receiveChan := make(chan struct{})
	receive := func() {
		receiveChan <- struct{}{}
	}

	reporter := &UsageReporter[TestEvent]{
		Entry:           l,
		events:          make(chan []*SubmittedEvent[TestEvent], 1),
		submissionQueue: make(chan []*SubmittedEvent[TestEvent], 1),
		submit:          submitter,
		clock:           clock,
		submitClock:     submitClock,
		minBatchSize:    testMinBatchSize,
		maxBatchSize:    testMaxBatchSize,
		maxBatchAge:     testMaxBatchAge,
		maxBufferSize:   testMaxBufferSize,
		submitDelay:     testSubmitDelay,
		receiveFunc:     receive,
		retryAttempts:   testRetryAttempts,
	}

	go reporter.Run(ctx)

	// Wait for timers to init.
	clock.BlockUntil(1)

	return reporter, cancel, receiveChan
}

// createDummyEvents creates a number of dummy events for testing
func createDummyEvents(start, count int) []*TestEvent {
	var ret []*TestEvent

	for i := 0; i < count; i++ {
		ret = append(ret, &TestEvent{
			count: fmt.Sprintf("%d", start+i),
		})
	}

	return ret
}

func compareUsageEvents(t *testing.T, reporter *UsageReporter[TestEvent], inputs []*TestEvent, outputs []*SubmittedEvent[TestEvent]) {
	require.Len(t, outputs, len(inputs))

	for i := 0; i < len(inputs); i++ {
		input := inputs[i]
		output := outputs[i]

		require.Equal(t, input.count, output.Event.count)
	}
}

// advanceClocks advances all the given clocks by the same duration
func advanceClocks(dur time.Duration, clocks ...clockwork.FakeClock) {
	for _, c := range clocks {
		c.Advance(dur)
	}
}

// TestUsageReporterTimeSubmit verifies event submission due to elapsed time.
func TestUsageReporterTimeSubmit(t *testing.T) {
	t.Parallel()

	fakeClock := clockwork.NewFakeClock()
	fakeSubmitClock := clockwork.NewFakeClock()
	submitter, batchChan := newTestSubmitter(2)

	reporter, cancel, rx := newTestingUsageReporter(fakeClock, fakeSubmitClock, submitter)
	defer cancel()

	// Create a few events, bot not enough to exceed minBatchSize.
	events := createDummyEvents(0, 2)
	reporter.AddEventsToQueue(events...)

	// Block until the events have been processed.
	<-rx

	// Advance a bit, but not enough to trigger a time-based submission.
	fakeClock.BlockUntil(1)
	advanceClocks(testMaxBatchAge/2, fakeClock, fakeSubmitClock)

	// Make sure no events show up.
	select {
	case e := <-batchChan:
		t.Fatalf("Received events too early: %+v", e)
	default:
		// Nothing to see yet.
	}

	// Advance more than enough to trigger a submission.
	// Note: only one batch for this test, so we don't care about the submit
	// clock.
	fakeClock.BlockUntil(1)
	advanceClocks(2*testMaxBatchAge, fakeClock, fakeSubmitClock)
	fakeSubmitClock.BlockUntil(1)

	select {
	case e := <-batchChan:
		require.Len(t, e, len(events))
		compareUsageEvents(t, reporter, events, e)
	case <-time.After(2 * time.Second):
		t.Fatalf("Did not receive expected events.")
	}
}

// TestUsageReporterBatchSubmit ensures batch size-based submission works as
// expected.
func TestUsageReporterBatchSubmit(t *testing.T) {
	t.Parallel()

	fakeClock := clockwork.NewFakeClock()
	fakeSubmitClock := clockwork.NewFakeClock()
	submitter, batchChan := newTestSubmitter(2)

	reporter, cancel, rx := newTestingUsageReporter(fakeClock, fakeSubmitClock, submitter)
	defer cancel()

	// Create enough events to fill a batch and then some.
	events := createDummyEvents(0, 10)
	reporter.AddEventsToQueue(events...)

	// Block until events have been processed.
	<-rx

	// Receive the first batch.
	select {
	case e := <-batchChan:
		require.Len(t, e, testMaxBatchSize)
		compareUsageEvents(t, reporter, events[:5], e)
	case <-time.After(time.Second):
		t.Fatalf("Did not receive expected events.")
	}

	// Submit an extra event to trigger an early send
	extra := createDummyEvents(9, 1)
	reporter.AddEventsToQueue(extra...)
	events = append(events, extra...)

	<-rx

	// Make sure the minimum delay is enforced for the subsequent batch.
	select {
	case e := <-batchChan:
		t.Fatalf("Received events too early: %+v", e)
	default:
		// Nothing to see yet.
	}

	// Wait for submission to complete due to the submission delay.
	fakeSubmitClock.BlockUntil(1)
	fakeClock.BlockUntil(1)
	advanceClocks(testSubmitDelay, fakeClock, fakeSubmitClock)

	// Receive the 2nd batch.
	select {
	case e := <-batchChan:
		require.Len(t, e, testMaxBatchSize)
		compareUsageEvents(t, reporter, events[5:10], e)
	case <-time.After(time.Second):
		t.Fatalf("Did not receive expected events.")
	}

	// Let the submission delay pass.
	fakeSubmitClock.BlockUntil(1)
	advanceClocks(testSubmitDelay, fakeClock, fakeSubmitClock)

	// With no new events, the final (added) event will be sent after the
	// regular interval.
	select {
	case e := <-batchChan:
		t.Fatalf("Received final event too early: %+v", e)
	default:
		// Nothing to see yet.
	}

	fakeClock.BlockUntil(1)
	advanceClocks(testMaxBatchAge, fakeClock, fakeSubmitClock)

	select {
	case e := <-batchChan:
		require.Len(t, e, 1)
		compareUsageEvents(t, reporter, events[10:], e)
	case <-time.After(time.Second):
		t.Fatalf("Did not receive expected events.")
	}
}

// TestUsageReporterDiscard validates that events are discarded when the buffer
// is full.
func TestUsageReporterDiscard(t *testing.T) {
	t.Parallel()

	fakeClock := clockwork.NewFakeClock()
	fakeSubmitClock := clockwork.NewFakeClock()
	submitter, batchChan := newTestSubmitter(2)

	reporter, cancel, rx := newTestingUsageReporter(fakeClock, fakeSubmitClock, submitter)
	defer cancel()

	// Create enough events to fill the buffer and then some.
	events := createDummyEvents(0, 12)
	reporter.AddEventsToQueue(events...)
	<-rx

	// Receive the first batch.
	select {
	case e := <-batchChan:
		require.Len(t, e, testMaxBatchSize)
		compareUsageEvents(t, reporter, events[:5], e)
	case <-time.After(time.Second):
		t.Fatalf("Did not receive expected events.")
	}

	// Wait the regular submit delay (to ensure submit finishes) _and_ the
	// maxBatchAge (to allow the next submission).
	fakeClock.BlockUntil(1)
	fakeSubmitClock.BlockUntil(1)
	advanceClocks(testSubmitDelay+testMaxBatchAge, fakeClock, fakeSubmitClock)

	// Receive the final batch.
	select {
	case e := <-batchChan:
		require.Len(t, e, testMaxBatchSize)
		compareUsageEvents(t, reporter, events[5:10], e)
	case <-time.After(time.Second):
		t.Fatalf("Did not receive expected events.")
	}

	// Wait again.
	advanceClocks(testMaxBatchAge*2, fakeClock, fakeSubmitClock)

	// Try to receive again. These events should have been discarded.
	select {
	case e := <-batchChan:
		t.Fatalf("Received unexpected events: %+v", e)
	default:
		// Nothing to see, no events should be left.
	}
}

// TestUsageReporterErrorReenqueue ensures failed events are added back to the
// queue and eventually dropped.
func TestUsageReporterErrorReenqueue(t *testing.T) {
	t.Parallel()

	fakeClock := clockwork.NewFakeClock()
	fakeSubmitClock := clockwork.NewFakeClock()
	submitter, batchChan := newFailingSubmitter(2)

	reporter, cancel, rx := newTestingUsageReporter(fakeClock, fakeSubmitClock, submitter)
	defer cancel()

	// Create enough events to fill the buffer.
	events := createDummyEvents(0, 10)
	reporter.AddEventsToQueue(events...)
	<-rx

	var prev []*SubmittedEvent[TestEvent]

	// Receive the first (failed) batch.
	select {
	case e := <-batchChan:
		require.Len(t, e, testMaxBatchSize)
		compareUsageEvents(t, reporter, events[:5], e)

		prev = e
	case <-time.After(time.Second):
		t.Fatalf("Did not receive expected events.")
	}

	// This failed, so the events were reenqueued. Ack the rx channel.
	<-rx

	// The submission fails, so events are reenqueued. This triggers an early
	// send at the submit delay rather than the full batch send interval.
	fakeClock.BlockUntil(1)
	fakeSubmitClock.BlockUntil(1)

	// Before continuing, check the last batch's retry counter. We need to check
	// this after the timers are ready, but before we advance the clock.
	for _, event := range prev {
		require.Equal(t, testRetryAttempts-1, event.retriesRemaining)
	}

	advanceClocks(testSubmitDelay, fakeClock, fakeSubmitClock)

	// Receive the second batch.
	select {
	case e := <-batchChan:
		require.Len(t, e, testMaxBatchSize)
		compareUsageEvents(t, reporter, events[5:10], e)

		prev = e
	case <-time.After(time.Second):
		t.Fatalf("Did not receive expected events.")
	}

	// Ack rx again.
	<-rx

	fakeClock.BlockUntil(1)
	fakeSubmitClock.BlockUntil(1)

	// As above, check the retry counter. These events still have only failed
	// once.
	for _, event := range prev {
		require.Equal(t, testRetryAttempts-1, event.retriesRemaining)
	}

	advanceClocks(testSubmitDelay, fakeClock, fakeSubmitClock)

	// Receive the first batch again, since it was reenqueued.
	select {
	case e := <-batchChan:
		require.Len(t, e, testMaxBatchSize)
		compareUsageEvents(t, reporter, events[:5], e)

		prev = e
	case <-time.After(time.Second):
		t.Fatalf("Did not receive expected events.")
	}

	<-rx

	fakeClock.BlockUntil(1)
	fakeSubmitClock.BlockUntil(1)

	// Now that it's been resubmitted once, retry attempts is lower.
	for _, event := range prev {
		require.Equal(t, 0, event.retriesRemaining)
	}

	advanceClocks(testSubmitDelay, fakeClock, fakeSubmitClock)

	// Receive the second batch again, since it was reenqueued.
	select {
	case e := <-batchChan:
		require.Len(t, e, testMaxBatchSize)
		compareUsageEvents(t, reporter, events[5:10], e)

		prev = e
	case <-time.After(time.Second):
		t.Fatalf("Did not receive expected events.")
	}

	<-rx
	fakeClock.BlockUntil(1)
	fakeSubmitClock.BlockUntil(1)

	// Now that it's been resubmitted once, retry attempts is lower.
	for _, event := range prev {
		require.Equal(t, 0, event.retriesRemaining)
	}

	// All events should have been dropped.
	require.Empty(t, reporter.buf)
}
