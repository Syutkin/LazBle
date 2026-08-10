unit LazBleLclDispatchTests;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  SyncObjs,
  FpcUnit,
  TestRegistry,
  LazBleLclDispatch;

type
  TTestDispatchMessage = class(TLazBleLclDispatchMessage)
  private
    FSequence: Integer;
    FPayload: TBytes;
  public
    constructor Create(const ASequence: Integer; const APayload: TBytes);
    function Clone: TLazBleLclDispatchMessage; override;
    procedure ChangeFirstByte(const AValue: Byte);
    property Sequence: Integer read FSequence;
    property Payload: TBytes read FPayload;
  end;

  TDispatchWorker = class(TThread)
  private
    FDispatch: TLazBleLclDispatch;
    FCount: Integer;
    FQueued: TEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(const ADispatch: TLazBleLclDispatch;
      const ACount: Integer);
    destructor Destroy; override;
    function WaitUntilQueued(const ATimeoutMs: Cardinal): TWaitResult;
  end;

  TLazBleLclDispatchTest = class(TTestCase)
  private
    FDispatch: TLazBleLclDispatch;
    FSequences: array of Integer;
    FPayloads: array of TBytes;
    FLastCallbackThreadId: TThreadID;
    procedure MessageDelivered(Sender: TObject;
      const AMessage: TLazBleLclDispatchMessage);
    procedure WaitForWorker(const AWorker: TDispatchWorker);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure BackgroundDeliveryRunsOnMainThreadAndCopiesPayload;
    procedure QueuedMessagesKeepSubmissionOrder;
    procedure NewGenerationDropsQueuedMessage;
    procedure DetachDropsQueuedMessage;
    procedure DestroyDropsQueuedMessage;
  end;

implementation

constructor TTestDispatchMessage.Create(const ASequence: Integer;
  const APayload: TBytes);
begin
  inherited Create;
  FSequence := ASequence;
  FPayload := Copy(APayload);
end;

function TTestDispatchMessage.Clone: TLazBleLclDispatchMessage;
begin
  Result := TTestDispatchMessage.Create(FSequence, FPayload);
end;

procedure TTestDispatchMessage.ChangeFirstByte(const AValue: Byte);
begin
  if Length(FPayload) > 0 then
    FPayload[0] := AValue;
end;

constructor TDispatchWorker.Create(const ADispatch: TLazBleLclDispatch;
  const ACount: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FDispatch := ADispatch;
  FCount := ACount;
  FQueued := TEvent.Create(nil, True, False, '');
end;

destructor TDispatchWorker.Destroy;
begin
  FQueued.Free;
  inherited Destroy;
end;

procedure TDispatchWorker.Execute;
var
  Index: Integer;
  Message: TTestDispatchMessage;
  Payload: TBytes;
begin
  try
    for Index := 1 to FCount do
    begin
      SetLength(Payload, 2);
      Payload[0] := Index;
      Payload[1] := Index + 10;
      Message := TTestDispatchMessage.Create(Index, Payload);
      try
        FDispatch.Queue(Message);
        Message.ChangeFirstByte(255);
      finally
        Message.Free;
      end;
    end;
  finally
    FQueued.SetEvent;
  end;
end;

function TDispatchWorker.WaitUntilQueued(
  const ATimeoutMs: Cardinal): TWaitResult;
begin
  Result := FQueued.WaitFor(ATimeoutMs);
end;

procedure TLazBleLclDispatchTest.SetUp;
begin
  inherited SetUp;
  FDispatch := TLazBleLclDispatch.Create(@MessageDelivered);
  SetLength(FSequences, 0);
  SetLength(FPayloads, 0);
  FLastCallbackThreadId := 0;
end;

procedure TLazBleLclDispatchTest.TearDown;
begin
  FDispatch.Free;
  FDispatch := nil;
  CheckSynchronize;
  inherited TearDown;
end;

procedure TLazBleLclDispatchTest.MessageDelivered(Sender: TObject;
  const AMessage: TLazBleLclDispatchMessage);
var
  Index: Integer;
  Message: TTestDispatchMessage;
begin
  Message := AMessage as TTestDispatchMessage;
  Index := Length(FSequences);
  SetLength(FSequences, Index + 1);
  SetLength(FPayloads, Index + 1);
  FSequences[Index] := Message.Sequence;
  FPayloads[Index] := Copy(Message.Payload);
  FLastCallbackThreadId := GetCurrentThreadId;
end;

procedure TLazBleLclDispatchTest.WaitForWorker(
  const AWorker: TDispatchWorker);
begin
  AssertEquals('Worker did not queue messages', Ord(wrSignaled),
    Ord(AWorker.WaitUntilQueued(5000)));
end;

procedure TLazBleLclDispatchTest.BackgroundDeliveryRunsOnMainThreadAndCopiesPayload;
var
  Worker: TDispatchWorker;
begin
  Worker := TDispatchWorker.Create(FDispatch, 1);
  try
    Worker.Start;
    WaitForWorker(Worker);
    AssertEquals(0, Length(FSequences));

    CheckSynchronize;

    AssertEquals(1, Length(FSequences));
    AssertEquals(1, FSequences[0]);
    AssertEquals(2, Length(FPayloads[0]));
    AssertEquals(1, Integer(FPayloads[0][0]));
    AssertEquals(11, Integer(FPayloads[0][1]));
    AssertEquals(Int64(MainThreadID), Int64(FLastCallbackThreadId));
  finally
    Worker.WaitFor;
    Worker.Free;
  end;
end;

procedure TLazBleLclDispatchTest.QueuedMessagesKeepSubmissionOrder;
var
  Worker: TDispatchWorker;
begin
  Worker := TDispatchWorker.Create(FDispatch, 3);
  try
    Worker.Start;
    WaitForWorker(Worker);

    CheckSynchronize;

    AssertEquals(3, Length(FSequences));
    AssertEquals(1, FSequences[0]);
    AssertEquals(2, FSequences[1]);
    AssertEquals(3, FSequences[2]);
  finally
    Worker.WaitFor;
    Worker.Free;
  end;
end;

procedure TLazBleLclDispatchTest.NewGenerationDropsQueuedMessage;
var
  Worker: TDispatchWorker;
begin
  Worker := TDispatchWorker.Create(FDispatch, 1);
  try
    Worker.Start;
    WaitForWorker(Worker);
    FDispatch.NextGeneration;

    CheckSynchronize;

    AssertEquals(0, Length(FSequences));
  finally
    Worker.WaitFor;
    Worker.Free;
  end;
end;

procedure TLazBleLclDispatchTest.DetachDropsQueuedMessage;
var
  Worker: TDispatchWorker;
begin
  Worker := TDispatchWorker.Create(FDispatch, 1);
  try
    Worker.Start;
    WaitForWorker(Worker);
    FDispatch.Detach;

    CheckSynchronize;

    AssertEquals(0, Length(FSequences));
  finally
    Worker.WaitFor;
    Worker.Free;
  end;
end;

procedure TLazBleLclDispatchTest.DestroyDropsQueuedMessage;
var
  Worker: TDispatchWorker;
begin
  Worker := TDispatchWorker.Create(FDispatch, 1);
  try
    Worker.Start;
    WaitForWorker(Worker);
    FDispatch.Free;
    FDispatch := nil;

    CheckSynchronize;

    AssertEquals(0, Length(FSequences));
  finally
    Worker.WaitFor;
    Worker.Free;
  end;
end;

initialization
  RegisterTest(TLazBleLclDispatchTest);

end.
