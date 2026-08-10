unit LazBleSimpleBleBackendTests;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  SyncObjs,
  fpcunit,
  testregistry,
  LazBleTypes,
  LazBleBackend,
  LazBleSimpleBleDriverIntf,
  LazBleSimpleBleBackend;

type
  TTestSimpleBleBackend = class(TLazBleSimpleBleBackend)
  public
    constructor CreateInternal(const ADriver: ILazBleSimpleBleDriver);
  end;

  TFakeSimpleBleDriver = class(TInterfacedObject, ILazBleSimpleBleDriver)
  private
    FStartedEvent: TEvent;
    FReleaseEvent: TEvent;
    FOpenCount: Integer;
    FCloseCount: Integer;
    FCancelCount: Integer;
    FExecuteCount: Integer;
    FBlockCommand: Boolean;
    FBlockedCommandKind: TLazBleBackendCommandKind;
    FLastEventSink: ILazBleSimpleBleDriverEventSink;
  public
    constructor Create;
    destructor Destroy; override;
    function Open(out AErrorMessage: string): Boolean;
    procedure Close;
    function Execute(const ACommand: TLazBleBackendCommand;
      const AOperationId: TBleOperationId;
      const AEventSink: ILazBleSimpleBleDriverEventSink;
      out AErrorCode: Integer; out AErrorMessage: string): Boolean;
    procedure CancelCurrent;
    procedure BlockCommand(const ACommandKind: TLazBleBackendCommandKind);
    function WaitUntilStarted: Boolean;
    procedure AllowCompletion;
    procedure EmitLateEvent;
    property OpenCount: Integer read FOpenCount;
    property CloseCount: Integer read FCloseCount;
    property CancelCount: Integer read FCancelCount;
    property ExecuteCount: Integer read FExecuteCount;
  end;

  TThreadSafeEventSink = class(TInterfacedObject, ILazBleBackendEventSink)
  private
    FLock: TRTLCriticalSection;
    FChangedEvent: TEvent;
    FEvents: array of TLazBleBackendEvent;
    function GetEvent(const AIndex: Integer): TLazBleBackendEvent;
  public
    constructor Create;
    destructor Destroy; override;
    procedure HandleBackendEvent(const AEvent: TLazBleBackendEvent);
    function EventCount: Integer;
    function WaitForEventCount(const ACount: Integer): Boolean;
    property Events[const AIndex: Integer]: TLazBleBackendEvent read GetEvent;
  end;

  TLazBleSimpleBleBackendTest = class(TTestCase)
  private
    FDriver: ILazBleSimpleBleDriver;
    FDriverObject: TFakeSimpleBleDriver;
    FBackend: ILazBleBackend;
    FEventSink: ILazBleBackendEventSink;
    FEventSinkObject: TThreadSafeEventSink;
    function SubmitScan: TBleOperationId;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure ScanRunsAsynchronouslyAndCopiesEvents;
    procedure CancelProducesOneCancelledTerminalEvent;
    procedure CancelBeforeStartSkipsDriverAndCompletesOnce;
    procedure CancelDuringGattIoCompletesOnce;
    procedure CancelAfterCompletionDoesNothing;
    procedure ShutdownCancelsScanAndClosesDriverFirst;
    procedure ShutdownCancelsActiveAndPendingGattOperations;
    procedure DestroyCancelsActiveOperationAndDetachesDriverSink;
    procedure ExplicitShutdownAndDestroyCloseDriverOnce;
    procedure DriverFailureIsDeliveredAsynchronously;
    procedure GattCommandsPreserveTypedProgressEvents;
    procedure EmitsNothingAfterTerminalShutdown;
    procedure DefaultBackendDoesNotLoadLibraryInConstructor;
  end;

implementation

constructor TTestSimpleBleBackend.CreateInternal(
  const ADriver: ILazBleSimpleBleDriver);
begin
  inherited Create(ADriver);
end;

constructor TFakeSimpleBleDriver.Create;
begin
  inherited Create;
  FStartedEvent := TEvent.Create(nil, True, False, '');
  FReleaseEvent := TEvent.Create(nil, True, False, '');
  FBlockCommand := True;
  FBlockedCommandKind := lbckStartScan;
end;

destructor TFakeSimpleBleDriver.Destroy;
begin
  FReleaseEvent.Free;
  FStartedEvent.Free;
  inherited Destroy;
end;

function TFakeSimpleBleDriver.Open(out AErrorMessage: string): Boolean;
begin
  Inc(FOpenCount);
  AErrorMessage := '';
  Result := True;
end;

procedure TFakeSimpleBleDriver.Close;
begin
  Inc(FCloseCount);
end;

function TFakeSimpleBleDriver.Execute(const ACommand: TLazBleBackendCommand;
  const AOperationId: TBleOperationId;
  const AEventSink: ILazBleSimpleBleDriverEventSink;
  out AErrorCode: Integer; out AErrorMessage: string): Boolean;
var
  BackendEvent: TLazBleBackendEvent;
begin
  FLastEventSink := AEventSink;
  Inc(FExecuteCount);
  if ACommand.Kind = lbckStopScan then
  begin
    AErrorCode := -1;
    AErrorMessage := 'Unsupported fake driver command';
    Exit(False);
  end;

  if FBlockCommand and (ACommand.Kind = FBlockedCommandKind) then
  begin
    FStartedEvent.SetEvent;
    FReleaseEvent.WaitFor(INFINITE);
  end;

  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.OperationId := AOperationId;
  BackendEvent.Generation := ACommand.Generation;
  BackendEvent.DeviceId := ACommand.DeviceId;
  BackendEvent.ServiceUuid := ACommand.ServiceUuid;
  BackendEvent.CharacteristicUuid := ACommand.CharacteristicUuid;
  case ACommand.Kind of
    lbckStartScan:
      begin
        BackendEvent.Kind := lbekScanStarted;
        BackendEvent.AdapterId := ACommand.AdapterId;
        AEventSink.Emit(BackendEvent);
        BackendEvent.Kind := lbekScanResult;
        BackendEvent.DeviceId := 'AA:BB:CC:DD:EE:FF';
        BackendEvent.DeviceName := 'ENTime';
        BackendEvent.Rssi := -42;
        AEventSink.Emit(BackendEvent);
        BackendEvent.Kind := lbekScanStopped;
        AEventSink.Emit(BackendEvent);
      end;
    lbckConnect:
      begin
        BackendEvent.Kind := lbekConnected;
        AEventSink.Emit(BackendEvent);
      end;
    lbckDisconnect:
      begin
        BackendEvent.Kind := lbekDisconnected;
        AEventSink.Emit(BackendEvent);
      end;
    lbckDiscoverServices:
      begin
        BackendEvent.Kind := lbekServicesDiscovered;
        AEventSink.Emit(BackendEvent);
      end;
    lbckRead:
      begin
        BackendEvent.Kind := lbekReadResult;
        BackendEvent.Value := [$58];
        AEventSink.Emit(BackendEvent);
      end;
    lbckWrite:
      begin
        BackendEvent.Kind := lbekWriteCompleted;
        AEventSink.Emit(BackendEvent);
      end;
    lbckSubscribe:
      begin
        BackendEvent.Kind := lbekSubscribed;
        BackendEvent.SubscriptionId := 21;
        AEventSink.Emit(BackendEvent);
      end;
    lbckUnsubscribe:
      begin
        BackendEvent.Kind := lbekUnsubscribed;
        BackendEvent.SubscriptionId := ACommand.SubscriptionId;
        AEventSink.Emit(BackendEvent);
      end;
  end;

  AErrorCode := 0;
  AErrorMessage := '';
  Result := True;
end;

procedure TFakeSimpleBleDriver.BlockCommand(
  const ACommandKind: TLazBleBackendCommandKind);
begin
  FBlockedCommandKind := ACommandKind;
  FBlockCommand := True;
  FStartedEvent.ResetEvent;
  FReleaseEvent.ResetEvent;
end;

procedure TFakeSimpleBleDriver.CancelCurrent;
begin
  Inc(FCancelCount);
  FReleaseEvent.SetEvent;
end;

procedure TLazBleSimpleBleBackendTest.CancelBeforeStartSkipsDriverAndCompletesOnce;
var
  ActiveCommand: TLazBleBackendCommand;
  ActiveOperationId: TBleOperationId;
  PendingCommand: TLazBleBackendCommand;
  PendingOperationId: TBleOperationId;
begin
  FDriverObject.BlockCommand(lbckRead);
  ActiveCommand := Default(TLazBleBackendCommand);
  ActiveCommand.Kind := lbckRead;
  ActiveOperationId := FBackend.Submit(ActiveCommand);
  AssertTrue(FDriverObject.WaitUntilStarted);

  PendingCommand := Default(TLazBleBackendCommand);
  PendingCommand.Kind := lbckWrite;
  PendingOperationId := FBackend.Submit(PendingCommand);
  FBackend.Cancel(PendingOperationId);
  FDriverObject.AllowCompletion;

  AssertTrue(FEventSinkObject.WaitForEventCount(3));
  AssertEquals(1, FDriverObject.ExecuteCount);
  AssertEquals(Ord(lbekOperationSucceeded),
    Ord(FEventSinkObject.Events[1].Kind));
  AssertTrue(ActiveOperationId = FEventSinkObject.Events[1].OperationId);
  AssertEquals(Ord(lbekOperationCancelled),
    Ord(FEventSinkObject.Events[2].Kind));
  AssertTrue(PendingOperationId = FEventSinkObject.Events[2].OperationId);
end;

procedure TLazBleSimpleBleBackendTest.CancelDuringGattIoCompletesOnce;
var
  Command: TLazBleBackendCommand;
  OperationId: TBleOperationId;
begin
  FDriverObject.BlockCommand(lbckRead);
  Command := Default(TLazBleBackendCommand);
  Command.Kind := lbckRead;
  OperationId := FBackend.Submit(Command);
  AssertTrue(FDriverObject.WaitUntilStarted);

  FBackend.Cancel(OperationId);

  AssertTrue(FEventSinkObject.WaitForEventCount(2));
  AssertEquals(1, FDriverObject.CancelCount);
  AssertEquals(1, FDriverObject.ExecuteCount);
  AssertEquals(Ord(lbekReadResult),
    Ord(FEventSinkObject.Events[0].Kind));
  AssertEquals(Ord(lbekOperationCancelled),
    Ord(FEventSinkObject.Events[1].Kind));
  AssertTrue(OperationId = FEventSinkObject.Events[1].OperationId);
end;

procedure TLazBleSimpleBleBackendTest.CancelAfterCompletionDoesNothing;
var
  Command: TLazBleBackendCommand;
  EventCountAfterCompletion: Integer;
  OperationId: TBleOperationId;
begin
  Command := Default(TLazBleBackendCommand);
  Command.Kind := lbckConnect;
  OperationId := FBackend.Submit(Command);
  AssertTrue(FEventSinkObject.WaitForEventCount(2));
  EventCountAfterCompletion := FEventSinkObject.EventCount;

  FBackend.Cancel(OperationId);

  AssertEquals(0, FDriverObject.CancelCount);
  AssertEquals(EventCountAfterCompletion, FEventSinkObject.EventCount);
end;

function TFakeSimpleBleDriver.WaitUntilStarted: Boolean;
begin
  Result := FStartedEvent.WaitFor(2000) = wrSignaled;
end;

procedure TFakeSimpleBleDriver.AllowCompletion;
begin
  FReleaseEvent.SetEvent;
end;

procedure TFakeSimpleBleDriver.EmitLateEvent;
var
  BackendEvent: TLazBleBackendEvent;
begin
  if not Assigned(FLastEventSink) then
    Exit;
  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := lbekNotification;
  BackendEvent.SubscriptionId := 99;
  FLastEventSink.Emit(BackendEvent);
end;

constructor TThreadSafeEventSink.Create;
begin
  inherited Create;
  InitCriticalSection(FLock);
  FChangedEvent := TEvent.Create(nil, True, False, '');
end;

destructor TThreadSafeEventSink.Destroy;
begin
  FChangedEvent.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function TThreadSafeEventSink.GetEvent(
  const AIndex: Integer): TLazBleBackendEvent;
begin
  EnterCriticalSection(FLock);
  try
    Result := FEvents[AIndex];
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TThreadSafeEventSink.HandleBackendEvent(
  const AEvent: TLazBleBackendEvent);
var
  Index: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Index := Length(FEvents);
    SetLength(FEvents, Index + 1);
    FEvents[Index] := AEvent;
    FChangedEvent.SetEvent;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TThreadSafeEventSink.EventCount: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Result := Length(FEvents);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TThreadSafeEventSink.WaitForEventCount(
  const ACount: Integer): Boolean;
var
  CurrentCount: Integer;
begin
  repeat
    EnterCriticalSection(FLock);
    try
      CurrentCount := Length(FEvents);
      if CurrentCount >= ACount then
        Exit(True);
      FChangedEvent.ResetEvent;
    finally
      LeaveCriticalSection(FLock);
    end;
  until FChangedEvent.WaitFor(2000) <> wrSignaled;
  Result := False;
end;

function TLazBleSimpleBleBackendTest.SubmitScan: TBleOperationId;
var
  Command: TLazBleBackendCommand;
begin
  Command := Default(TLazBleBackendCommand);
  Command.Kind := lbckStartScan;
  Command.AdapterId := 'hci0';
  Command.TimeoutMs := 5000;
  Result := FBackend.Submit(Command);
end;

procedure TLazBleSimpleBleBackendTest.SetUp;
begin
  FDriverObject := TFakeSimpleBleDriver.Create;
  FDriver := FDriverObject;
  FBackend := TTestSimpleBleBackend.CreateInternal(FDriver);
  FEventSinkObject := TThreadSafeEventSink.Create;
  FEventSink := FEventSinkObject;
  FBackend.SetEventSink(FEventSink);
end;

procedure TLazBleSimpleBleBackendTest.TearDown;
begin
  if Assigned(FBackend) then
    FBackend.SetEventSink(nil);
  FEventSink := nil;
  FEventSinkObject := nil;
  FBackend := nil;
  FDriver := nil;
  FDriverObject := nil;
end;

procedure TLazBleSimpleBleBackendTest.ScanRunsAsynchronouslyAndCopiesEvents;
var
  OperationId: TBleOperationId;
begin
  OperationId := SubmitScan;
  AssertTrue(FDriverObject.WaitUntilStarted);
  AssertEquals(0, FEventSinkObject.EventCount);

  FDriverObject.AllowCompletion;
  AssertTrue(FEventSinkObject.WaitForEventCount(4));

  AssertEquals(Ord(lbekScanStarted), Ord(FEventSinkObject.Events[0].Kind));
  AssertEquals(Ord(lbekScanResult), Ord(FEventSinkObject.Events[1].Kind));
  AssertEquals('AA:BB:CC:DD:EE:FF', FEventSinkObject.Events[1].DeviceId);
  AssertEquals('ENTime', FEventSinkObject.Events[1].DeviceName);
  AssertEquals(-42, Integer(FEventSinkObject.Events[1].Rssi));
  AssertEquals(Ord(lbekScanStopped), Ord(FEventSinkObject.Events[2].Kind));
  AssertEquals(Ord(lbekOperationSucceeded),
    Ord(FEventSinkObject.Events[3].Kind));
  AssertTrue(OperationId = FEventSinkObject.Events[3].OperationId);
  AssertEquals(1, FDriverObject.OpenCount);
end;

procedure TLazBleSimpleBleBackendTest.CancelProducesOneCancelledTerminalEvent;
var
  OperationId: TBleOperationId;
begin
  OperationId := SubmitScan;
  AssertTrue(FDriverObject.WaitUntilStarted);
  FBackend.Cancel(OperationId);

  AssertTrue(FEventSinkObject.WaitForEventCount(4));
  AssertEquals(1, FDriverObject.CancelCount);
  AssertEquals(Ord(lbekOperationCancelled),
    Ord(FEventSinkObject.Events[3].Kind));
end;

procedure TLazBleSimpleBleBackendTest.ShutdownCancelsScanAndClosesDriverFirst;
var
  ShutdownId: TBleOperationId;
begin
  SubmitScan;
  AssertTrue(FDriverObject.WaitUntilStarted);
  ShutdownId := FBackend.BeginShutdown;

  AssertTrue(FEventSinkObject.WaitForEventCount(5));
  AssertEquals(1, FDriverObject.CloseCount);
  AssertEquals(Ord(lbekOperationCancelled),
    Ord(FEventSinkObject.Events[3].Kind));
  AssertEquals(Ord(lbekShutdownCompleted),
    Ord(FEventSinkObject.Events[4].Kind));
  AssertTrue(ShutdownId = FEventSinkObject.Events[4].OperationId);
end;

procedure TLazBleSimpleBleBackendTest.ShutdownCancelsActiveAndPendingGattOperations;
var
  ActiveCommand: TLazBleBackendCommand;
  ActiveOperationId: TBleOperationId;
  PendingCommand: TLazBleBackendCommand;
  PendingOperationId: TBleOperationId;
  SecondPendingOperationId: TBleOperationId;
  ShutdownId: TBleOperationId;
begin
  FDriverObject.BlockCommand(lbckRead);
  ActiveCommand := Default(TLazBleBackendCommand);
  ActiveCommand.Kind := lbckRead;
  ActiveOperationId := FBackend.Submit(ActiveCommand);
  AssertTrue(FDriverObject.WaitUntilStarted);

  PendingCommand := Default(TLazBleBackendCommand);
  PendingCommand.Kind := lbckWrite;
  PendingOperationId := FBackend.Submit(PendingCommand);
  PendingCommand.Kind := lbckSubscribe;
  SecondPendingOperationId := FBackend.Submit(PendingCommand);

  ShutdownId := FBackend.BeginShutdown;

  AssertTrue(FEventSinkObject.WaitForEventCount(5));
  AssertEquals(1, FDriverObject.CancelCount);
  AssertEquals(1, FDriverObject.ExecuteCount);
  AssertEquals(1, FDriverObject.CloseCount);
  AssertEquals(Ord(lbekOperationCancelled),
    Ord(FEventSinkObject.Events[1].Kind));
  AssertTrue(ActiveOperationId = FEventSinkObject.Events[1].OperationId);
  AssertEquals(Ord(lbekOperationCancelled),
    Ord(FEventSinkObject.Events[2].Kind));
  AssertTrue(PendingOperationId = FEventSinkObject.Events[2].OperationId);
  AssertEquals(Ord(lbekOperationCancelled),
    Ord(FEventSinkObject.Events[3].Kind));
  AssertTrue(SecondPendingOperationId =
    FEventSinkObject.Events[3].OperationId);
  AssertEquals(Ord(lbekShutdownCompleted),
    Ord(FEventSinkObject.Events[4].Kind));
  AssertTrue(ShutdownId = FEventSinkObject.Events[4].OperationId);
end;

procedure TLazBleSimpleBleBackendTest.DestroyCancelsActiveOperationAndDetachesDriverSink;
var
  Command: TLazBleBackendCommand;
  EventCountAfterDestroy: Integer;
begin
  FDriverObject.BlockCommand(lbckRead);
  Command := Default(TLazBleBackendCommand);
  Command.Kind := lbckRead;
  FBackend.Submit(Command);
  AssertTrue(FDriverObject.WaitUntilStarted);

  FBackend := nil;

  AssertEquals(1, FDriverObject.CancelCount);
  AssertEquals(1, FDriverObject.CloseCount);
  EventCountAfterDestroy := FEventSinkObject.EventCount;
  AssertTrue(EventCountAfterDestroy >= 3);
  AssertEquals(Ord(lbekShutdownCompleted),
    Ord(FEventSinkObject.Events[EventCountAfterDestroy - 1].Kind));

  FDriverObject.EmitLateEvent;

  AssertEquals(EventCountAfterDestroy, FEventSinkObject.EventCount);
end;

procedure TLazBleSimpleBleBackendTest.ExplicitShutdownAndDestroyCloseDriverOnce;
var
  ShutdownId: TBleOperationId;
begin
  ShutdownId := FBackend.BeginShutdown;
  AssertTrue(ShutdownId <> InvalidBleOperationId);
  AssertTrue(FEventSinkObject.WaitForEventCount(1));
  AssertEquals(1, FDriverObject.CloseCount);

  FBackend := nil;

  AssertEquals(1, FDriverObject.CloseCount);
end;

procedure TLazBleSimpleBleBackendTest.DriverFailureIsDeliveredAsynchronously;
var
  Command: TLazBleBackendCommand;
  OperationId: TBleOperationId;
begin
  Command := Default(TLazBleBackendCommand);
  Command.Kind := lbckStopScan;
  OperationId := FBackend.Submit(Command);

  AssertTrue(FEventSinkObject.WaitForEventCount(1));
  AssertEquals(Ord(lbekOperationFailed),
    Ord(FEventSinkObject.Events[0].Kind));
  AssertTrue(OperationId = FEventSinkObject.Events[0].OperationId);
  AssertTrue(FEventSinkObject.Events[0].ErrorMessage <> '');
end;

procedure TLazBleSimpleBleBackendTest.GattCommandsPreserveTypedProgressEvents;
const
  ExpectedKinds: array[0..6] of TLazBleBackendEventKind = (
    lbekConnected,
    lbekServicesDiscovered,
    lbekReadResult,
    lbekWriteCompleted,
    lbekSubscribed,
    lbekUnsubscribed,
    lbekDisconnected
  );
  CommandKinds: array[0..6] of TLazBleBackendCommandKind = (
    lbckConnect,
    lbckDiscoverServices,
    lbckRead,
    lbckWrite,
    lbckSubscribe,
    lbckUnsubscribe,
    lbckDisconnect
  );
var
  Command: TLazBleBackendCommand;
  Index: Integer;
  OperationId: TBleOperationId;
begin
  for Index := 0 to High(CommandKinds) do
  begin
    Command := Default(TLazBleBackendCommand);
    Command.Kind := CommandKinds[Index];
    Command.Generation := 7;
    Command.DeviceId := 'AA:BB:CC:DD:EE:FF';
    Command.ServiceUuid := '180f';
    Command.CharacteristicUuid := '2a19';
    Command.SubscriptionId := 21;
    OperationId := FBackend.Submit(Command);
    AssertTrue(FEventSinkObject.WaitForEventCount((Index + 1) * 2));

    AssertEquals(Ord(ExpectedKinds[Index]),
      Ord(FEventSinkObject.Events[Index * 2].Kind));
    AssertTrue(OperationId = FEventSinkObject.Events[Index * 2].OperationId);
    AssertEquals(7, Integer(FEventSinkObject.Events[Index * 2].Generation));
    AssertEquals('AA:BB:CC:DD:EE:FF',
      FEventSinkObject.Events[Index * 2].DeviceId);
    AssertEquals(Ord(lbekOperationSucceeded),
      Ord(FEventSinkObject.Events[Index * 2 + 1].Kind));
  end;
  AssertEquals($58, Integer(FEventSinkObject.Events[4].Value[0]));
  AssertTrue(FEventSinkObject.Events[8].SubscriptionId = 21);
  AssertTrue(FEventSinkObject.Events[10].SubscriptionId = 21);
end;

procedure TLazBleSimpleBleBackendTest.EmitsNothingAfterTerminalShutdown;
var
  Command: TLazBleBackendCommand;
  EventCountAfterShutdown: Integer;
begin
  Command := Default(TLazBleBackendCommand);
  Command.Kind := lbckConnect;
  Command.DeviceId := 'AA:BB:CC:DD:EE:FF';
  FBackend.Submit(Command);
  AssertTrue(FEventSinkObject.WaitForEventCount(2));

  FBackend.BeginShutdown;
  AssertTrue(FEventSinkObject.WaitForEventCount(3));
  EventCountAfterShutdown := FEventSinkObject.EventCount;
  AssertTrue(FBackend.Submit(Command) = InvalidBleOperationId);
  FDriverObject.EmitLateEvent;

  AssertEquals(EventCountAfterShutdown, FEventSinkObject.EventCount);
  AssertEquals(Ord(lbekShutdownCompleted),
    Ord(FEventSinkObject.Events[EventCountAfterShutdown - 1].Kind));
end;

procedure TLazBleSimpleBleBackendTest.DefaultBackendDoesNotLoadLibraryInConstructor;
var
  Backend: ILazBleBackend;
begin
  Backend := TLazBleSimpleBleBackend.Create;
  AssertTrue(Assigned(Backend));
  AssertTrue(Backend.BeginShutdown <> InvalidBleOperationId);
  Backend := nil;
end;

initialization
  RegisterTest(TLazBleSimpleBleBackendTest);

end.
