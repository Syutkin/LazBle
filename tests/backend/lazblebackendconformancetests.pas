unit LazBleBackendConformanceTests;

{$mode objfpc}{$H+}

interface

uses
  fpcunit,
  testregistry,
  LazBleTypes,
  LazBleBackend,
  FakeLazBleBackend;

type
  TConformanceEventSink = class(TInterfacedObject, ILazBleBackendEventSink)
  private
    FEvents: array of TLazBleBackendEvent;
    function GetEvent(const AIndex: Integer): TLazBleBackendEvent;
  public
    procedure HandleBackendEvent(const AEvent: TLazBleBackendEvent);
    function EventCount: Integer;
    property Events[const AIndex: Integer]: TLazBleBackendEvent read GetEvent;
  end;

  { Subclass this suite for every backend test harness. The harness methods
    stimulate asynchronous completion without prescribing backend internals. }
  TLazBleBackendConformanceTest = class abstract(TTestCase)
  private
    FBackend: ILazBleBackend;
    FEventSink: ILazBleBackendEventSink;
    FEventSinkObject: TConformanceEventSink;
    function SubmitCommand: TBleOperationId;
  protected
    function CreateBackend: ILazBleBackend; virtual; abstract;
    function CompleteOperation(const AOperationId: TBleOperationId;
      const AEventKind: TLazBleBackendEventKind): Boolean; virtual; abstract;
    function CompleteShutdown: Boolean; virtual; abstract;
    function EmitProgress(const AEvent: TLazBleBackendEvent): Boolean;
      virtual; abstract;
    function CancellationWasRequested(
      const AOperationId: TBleOperationId): Boolean; virtual; abstract;
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure DeliversExactlyOneTerminalEventPerOperation;
    procedure CancelCompletesAsynchronously;
    procedure AllowsQueuedProgressWhileCancellationIsPending;
    procedure ShutdownCancelsOperationsBeforeCompleting;
    procedure PreservesStaleEventIdentityUntilShutdownCompletes;
    procedure RejectsOperationProgressAfterTerminalEvent;
    procedure EmitsNothingAfterTerminalShutdown;
  end;

  TFakeLazBleBackendConformanceTest = class(TLazBleBackendConformanceTest)
  private
    FFakeBackend: TFakeLazBleBackend;
  protected
    function CreateBackend: ILazBleBackend; override;
    function CompleteOperation(const AOperationId: TBleOperationId;
      const AEventKind: TLazBleBackendEventKind): Boolean; override;
    function CompleteShutdown: Boolean; override;
    function EmitProgress(const AEvent: TLazBleBackendEvent): Boolean; override;
    function CancellationWasRequested(
      const AOperationId: TBleOperationId): Boolean; override;
    procedure TearDown; override;
  end;

implementation

function TConformanceEventSink.GetEvent(
  const AIndex: Integer): TLazBleBackendEvent;
begin
  Result := FEvents[AIndex];
end;

procedure TConformanceEventSink.HandleBackendEvent(
  const AEvent: TLazBleBackendEvent);
var
  Index: Integer;
begin
  Index := Length(FEvents);
  SetLength(FEvents, Index + 1);
  FEvents[Index] := AEvent;
end;

function TConformanceEventSink.EventCount: Integer;
begin
  Result := Length(FEvents);
end;

function TLazBleBackendConformanceTest.SubmitCommand: TBleOperationId;
var
  Command: TLazBleBackendCommand;
begin
  Command := Default(TLazBleBackendCommand);
  Command.Kind := lbckRead;
  Command.DeviceId := 'device-1';
  Command.ServiceUuid := '180f';
  Command.CharacteristicUuid := '2a19';
  Result := FBackend.Submit(Command);
end;

procedure TLazBleBackendConformanceTest.SetUp;
begin
  FBackend := CreateBackend;
  FEventSinkObject := TConformanceEventSink.Create;
  FEventSink := FEventSinkObject;
  FBackend.SetEventSink(FEventSink);
end;

procedure TLazBleBackendConformanceTest.TearDown;
begin
  if Assigned(FBackend) then
    FBackend.SetEventSink(nil);
  FEventSink := nil;
  FEventSinkObject := nil;
  FBackend := nil;
end;

procedure TLazBleBackendConformanceTest.DeliversExactlyOneTerminalEventPerOperation;
var
  OperationId: TBleOperationId;
begin
  OperationId := SubmitCommand;

  AssertTrue(CompleteOperation(OperationId, lbekOperationSucceeded));
  AssertFalse(CompleteOperation(OperationId, lbekOperationFailed));
  AssertFalse(CompleteOperation(OperationId, lbekOperationCancelled));

  AssertEquals(1, FEventSinkObject.EventCount);
  AssertEquals(Ord(lbekOperationSucceeded),
    Ord(FEventSinkObject.Events[0].Kind));
  AssertTrue(OperationId = FEventSinkObject.Events[0].OperationId);
end;

procedure TLazBleBackendConformanceTest.CancelCompletesAsynchronously;
var
  OperationId: TBleOperationId;
begin
  OperationId := SubmitCommand;

  FBackend.Cancel(OperationId);

  AssertEquals(0, FEventSinkObject.EventCount);
  AssertTrue(CancellationWasRequested(OperationId));
  AssertTrue(CompleteOperation(OperationId, lbekOperationCancelled));
  AssertEquals(1, FEventSinkObject.EventCount);
  AssertEquals(Ord(lbekOperationCancelled),
    Ord(FEventSinkObject.Events[0].Kind));
end;

procedure TLazBleBackendConformanceTest.AllowsQueuedProgressWhileCancellationIsPending;
var
  OperationId: TBleOperationId;
  BackendEvent: TLazBleBackendEvent;
begin
  OperationId := SubmitCommand;
  FBackend.Cancel(OperationId);

  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := lbekReadResult;
  BackendEvent.OperationId := OperationId;
  BackendEvent.Generation := 5;
  AssertTrue(EmitProgress(BackendEvent));
  AssertTrue(CompleteOperation(OperationId, lbekOperationCancelled));

  AssertEquals(2, FEventSinkObject.EventCount);
  AssertEquals(Ord(lbekReadResult), Ord(FEventSinkObject.Events[0].Kind));
  AssertTrue(OperationId = FEventSinkObject.Events[0].OperationId);
  AssertTrue(FEventSinkObject.Events[0].Generation = 5);
  AssertEquals(Ord(lbekOperationCancelled),
    Ord(FEventSinkObject.Events[1].Kind));
end;

procedure TLazBleBackendConformanceTest.ShutdownCancelsOperationsBeforeCompleting;
var
  FirstOperationId: TBleOperationId;
  SecondOperationId: TBleOperationId;
  ShutdownId: TBleOperationId;
begin
  FirstOperationId := SubmitCommand;
  SecondOperationId := SubmitCommand;

  ShutdownId := FBackend.BeginShutdown;

  AssertTrue(ShutdownId <> InvalidBleOperationId);
  AssertTrue(ShutdownId = FBackend.BeginShutdown);
  AssertEquals(0, FEventSinkObject.EventCount);
  AssertTrue(CancellationWasRequested(FirstOperationId));
  AssertTrue(CancellationWasRequested(SecondOperationId));
  AssertTrue(SubmitCommand = InvalidBleOperationId);
  AssertFalse(CompleteShutdown);

  AssertTrue(CompleteOperation(FirstOperationId, lbekOperationCancelled));
  AssertTrue(CompleteOperation(SecondOperationId, lbekOperationCancelled));
  AssertTrue(CompleteShutdown);

  AssertEquals(3, FEventSinkObject.EventCount);
  AssertTrue(FirstOperationId = FEventSinkObject.Events[0].OperationId);
  AssertTrue(SecondOperationId = FEventSinkObject.Events[1].OperationId);
  AssertEquals(Ord(lbekShutdownCompleted),
    Ord(FEventSinkObject.Events[2].Kind));
  AssertTrue(ShutdownId = FEventSinkObject.Events[2].OperationId);
end;

procedure TLazBleBackendConformanceTest.PreservesStaleEventIdentityUntilShutdownCompletes;
var
  OperationId: TBleOperationId;
  BackendEvent: TLazBleBackendEvent;
begin
  OperationId := SubmitCommand;
  AssertTrue(CompleteOperation(OperationId, lbekOperationSucceeded));

  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := lbekNotification;
  BackendEvent.OperationId := InvalidBleOperationId;
  BackendEvent.SubscriptionId := 17;
  BackendEvent.Generation := 4;
  BackendEvent.DeviceId := 'device-1';
  AssertTrue(EmitProgress(BackendEvent));

  AssertEquals(2, FEventSinkObject.EventCount);
  AssertEquals(Ord(lbekNotification), Ord(FEventSinkObject.Events[1].Kind));
  AssertTrue(FEventSinkObject.Events[1].OperationId = InvalidBleOperationId);
  AssertTrue(FEventSinkObject.Events[1].SubscriptionId = 17);
  AssertTrue(FEventSinkObject.Events[1].Generation = 4);
end;

procedure TLazBleBackendConformanceTest.RejectsOperationProgressAfterTerminalEvent;
var
  OperationId: TBleOperationId;
  BackendEvent: TLazBleBackendEvent;
begin
  OperationId := SubmitCommand;
  AssertTrue(CompleteOperation(OperationId, lbekOperationSucceeded));

  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := lbekReadResult;
  BackendEvent.OperationId := OperationId;
  AssertFalse(EmitProgress(BackendEvent));

  AssertEquals(1, FEventSinkObject.EventCount);
end;

procedure TLazBleBackendConformanceTest.EmitsNothingAfterTerminalShutdown;
var
  ShutdownId: TBleOperationId;
  BackendEvent: TLazBleBackendEvent;
begin
  ShutdownId := FBackend.BeginShutdown;
  AssertTrue(CompleteShutdown);
  AssertEquals(1, FEventSinkObject.EventCount);

  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := lbekScanResult;
  BackendEvent.OperationId := 99;
  AssertFalse(EmitProgress(BackendEvent));
  AssertFalse(CompleteOperation(99, lbekOperationSucceeded));
  AssertTrue(ShutdownId = FBackend.BeginShutdown);

  AssertEquals(1, FEventSinkObject.EventCount);
end;

function TFakeLazBleBackendConformanceTest.CreateBackend: ILazBleBackend;
begin
  FFakeBackend := TFakeLazBleBackend.Create;
  Result := FFakeBackend;
end;

function TFakeLazBleBackendConformanceTest.CompleteOperation(
  const AOperationId: TBleOperationId;
  const AEventKind: TLazBleBackendEventKind): Boolean;
begin
  Result := FFakeBackend.CompleteOperation(AOperationId, AEventKind);
end;

function TFakeLazBleBackendConformanceTest.CompleteShutdown: Boolean;
begin
  Result := FFakeBackend.CompleteShutdown;
end;

function TFakeLazBleBackendConformanceTest.EmitProgress(
  const AEvent: TLazBleBackendEvent): Boolean;
begin
  Result := FFakeBackend.EmitProgress(AEvent);
end;

function TFakeLazBleBackendConformanceTest.CancellationWasRequested(
  const AOperationId: TBleOperationId): Boolean;
begin
  Result := FFakeBackend.CancellationWasRequested(AOperationId);
end;

procedure TFakeLazBleBackendConformanceTest.TearDown;
begin
  inherited TearDown;
  FFakeBackend := nil;
end;

initialization
  RegisterTest(TFakeLazBleBackendConformanceTest);

end.
