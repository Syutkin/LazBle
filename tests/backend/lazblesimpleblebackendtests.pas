unit LazBleSimpleBleBackendTests;

{$mode objfpc}{$H+}

interface

uses Classes, SysUtils, fpcunit, testregistry, SimpleDelphiBLE,
  LazBleTypes, LazBleBackend, LazBleSimpleBleBackend, LazBleFacade,
  LazBleClient, LazBleOperation, LazBleBattery, LazBleGattProfile, LazBleSync;

type
  TNativeEventSink = class(TInterfacedObject, ILazBleBackendEventSink)
  public
    Events: array of TLazBleBackendEvent;
    WrongThread: Integer;
    CancelOnConnect, ShutdownBackend: ILazBleBackend;
    ShutdownOn: TLazBleBackendEventKind;
    procedure HandleBackendEvent(const Event: TLazBleBackendEvent);
    function Count(Kind: TLazBleBackendEventKind; Id: TBleOperationId = 0): Integer;
    function Last(Kind: TLazBleBackendEventKind; Id: TBleOperationId = 0): TLazBleBackendEvent;
    function Terminal(Id: TBleOperationId): Boolean;
  end;

  { Real SimpleDelphiBLE + the upstream 1.3.0 PLAIN native implementation.
    Deliberately no injected driver or imitation of the public binding API. }
  TLazBleSimpleBleBackendTest = class(TTestCase)
  private
    FBackend: ILazBleBackend;
    FSink: ILazBleBackendEventSink;
    FEvents: TNativeEventSink;
    function Request(Kind: TLazBleBackendCommandKind): TLazBleBackendCommand;
    function Send(Kind: TLazBleBackendCommandKind): TBleOperationId;
    function Wait(Id: TBleOperationId): TLazBleBackendEvent;
    procedure Pump(Ms: Cardinal);
    procedure WaitForEvent(Kind: TLazBleBackendEventKind; Count: Integer = 1);
    procedure Connect;
    procedure Shutdown;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure AvailabilityAndAdapterSelection;
    procedure MissingAdapterIsAsyncFailure;
    procedure PoweredOffAdapterIsUnavailable;
    procedure ScanUsesMainThreadEventsAndFinalSnapshot;
    procedure StopScanWakesWorker;
    procedure QueuedCancellationSkipsNativeCall;
    procedure ConnectDiscoveryAndGatt;
    procedure NativeErrorZeroIsFailure;
    procedure NativeAttErrorIsPreserved;
    procedure NotificationAndUnsubscribe;
    procedure DuplicateSubscriptionDoesNotReplaceHandler;
    procedure StartedConnectReportsActualOutcome;
    procedure DisconnectAndReconnect;
    procedure ShutdownDrainsScanAndQueuedCommands;
    procedure ShutdownCleansActiveSubscription;
    procedure BackendCanBeRecreated;
    procedure OnlyOneBackendOwnsNativeCallbacks;
    procedure PublicApiRequiresMainThread;
    procedure SinkCanBeDetached;
    procedure FacadeAndBatteryProfileUseNativeBackend;
    procedure UnsubscribeAfterLinkLossRetiresHandler;
    procedure ShutdownWhileNativeConnectCompletes;
    procedure ShutdownFromSubscribeCompletion;
    procedure NativeFacadeReconnectUsesMainThreadTimer;
    procedure NativeSyncPumpsMainThreadEvents;
  end;

implementation

const
  Device = '11:22:33:44:55:66';
  BatteryService = '0000180f-0000-1000-8000-00805f9b34fb';
  BatteryValue = '00002a19-0000-1000-8000-00805f9b34fb';
  TestService = '0000fff0-0000-1000-8000-00805f9b34fb';
  TestValue = '0000fff1-0000-1000-8000-00805f9b34fb';
  ErrorValue = '0000fff2-0000-1000-8000-00805f9b34fb';

type
  TClientGenerationAccess = class(TBleClient)
    function CurrentGeneration: QWord;
  end;

  TNativeDisconnect = class(TThread)
    Peer: TBlePeripheral;
    procedure Execute; override;
  end;

  TWrongThreadCall = class(TThread)
    Backend: ILazBleBackend;
    Rejected: Boolean;
    procedure Execute; override;
  end;

function TClientGenerationAccess.CurrentGeneration: QWord;
begin Result := Generation; end;

procedure TNativeDisconnect.Execute;
begin
  Peer.Disconnect;
end;

procedure TWrongThreadCall.Execute;
begin
  try
    Backend.Submit(Default(TLazBleBackendCommand));
  except
    on E: EInvalidOperation do Rejected := True;
  end;
end;

procedure TNativeEventSink.HandleBackendEvent(const Event: TLazBleBackendEvent);
var N: Integer;
begin
  if GetCurrentThreadID <> MainThreadID then Inc(WrongThread);
  N := Length(Events);
  SetLength(Events, N + 1);
  Events[N] := Event;
  if (Event.Kind = lbekConnected) and (CancelOnConnect <> nil) then
    CancelOnConnect.Cancel(Event.OperationId);
  if (ShutdownBackend <> nil) and (Event.Kind = ShutdownOn) then
    ShutdownBackend.BeginShutdown;
end;

function TNativeEventSink.Count(Kind: TLazBleBackendEventKind; Id: TBleOperationId): Integer;
var E: TLazBleBackendEvent;
begin
  Result := 0;
  for E in Events do
    if (E.Kind = Kind) and ((Id = 0) or (E.OperationId = Id)) then Inc(Result);
end;

function TNativeEventSink.Last(Kind: TLazBleBackendEventKind; Id: TBleOperationId): TLazBleBackendEvent;
var I: Integer;
begin
  for I := High(Events) downto 0 do
    if (Events[I].Kind = Kind) and ((Id = 0) or (Events[I].OperationId = Id)) then Exit(Events[I]);
  raise Exception.CreateFmt('Event %d for operation %d not received', [Ord(Kind), Id]);
end;

function TNativeEventSink.Terminal(Id: TBleOperationId): Boolean;
var E: TLazBleBackendEvent;
begin
  for E in Events do
    if (E.OperationId = Id) and LazBleBackendEventIsTerminal(E) then Exit(True);
  Result := False;
end;

procedure TLazBleSimpleBleBackendTest.SetUp;
begin
  AssertEquals('Tests require upstream PLAIN, never real Bluetooth hardware',
    'Plain', UTF8Encode(SimpleDelphiBLE.TBleBackend.GetNative.Identifier));
  TBleAdapter.GetAdapters[0].PowerOn;
  FEvents := TNativeEventSink.Create;
  FSink := FEvents;
  FBackend := TLazBleSimpleBleBackend.Create;
  FBackend.SetEventSink(FSink);
end;

procedure TLazBleSimpleBleBackendTest.TearDown;
begin
  FEvents.CancelOnConnect := nil;
  FEvents.ShutdownBackend := nil;
  Shutdown;
  AssertEquals('Every event delivered on the main thread', 0, FEvents.WrongThread);
  FBackend.SetEventSink(nil);
  FBackend := nil;
  FSink := nil;
end;

function TLazBleSimpleBleBackendTest.Request(Kind: TLazBleBackendCommandKind): TLazBleBackendCommand;
begin
  Result := Default(TLazBleBackendCommand);
  Result.Kind := Kind;
  Result.DeviceId := Device;
  Result.Generation := 7;
  Result.ServiceUuid := TestService;
  Result.CharacteristicUuid := TestValue;
  Result.TimeoutMs := 200;
end;

function TLazBleSimpleBleBackendTest.Send(Kind: TLazBleBackendCommandKind): TBleOperationId;
begin
  Result := FBackend.Submit(Request(Kind));
  AssertTrue('Operation accepted', Result <> InvalidBleOperationId);
end;

procedure TLazBleSimpleBleBackendTest.Pump(Ms: Cardinal);
var Deadline: QWord;
begin
  Deadline := GetTickCount64 + Ms;
  repeat CheckSynchronize(5); until GetTickCount64 >= Deadline;
end;

procedure TLazBleSimpleBleBackendTest.WaitForEvent(Kind: TLazBleBackendEventKind; Count: Integer);
var Deadline: QWord;
begin
  Deadline := GetTickCount64 + 8000;
  while (FEvents.Count(Kind) < Count) and (GetTickCount64 < Deadline) do CheckSynchronize(5);
  AssertTrue('Expected event ' + IntToStr(Ord(Kind)), FEvents.Count(Kind) >= Count);
end;

function TLazBleSimpleBleBackendTest.Wait(Id: TBleOperationId): TLazBleBackendEvent;
var Deadline: QWord; E: TLazBleBackendEvent; N: Integer;
begin
  Deadline := GetTickCount64 + 8000;
  while not FEvents.Terminal(Id) and (GetTickCount64 < Deadline) do CheckSynchronize(5);
  AssertTrue('Operation completed', FEvents.Terminal(Id));
  N := 0;
  Result := Default(TLazBleBackendEvent);
  for E in FEvents.Events do
    if (E.OperationId = Id) and LazBleBackendEventIsTerminal(E) then
    begin
      Inc(N);
      Result := E;
    end;
  AssertEquals('Exactly one terminal event', 1, N);
end;

procedure TLazBleSimpleBleBackendTest.Connect;
var Id: TBleOperationId; E: TLazBleBackendEvent;
begin
  Id := Send(lbckConnect);
  E := Wait(Id);
  AssertEquals(E.ErrorMessage, Ord(lbekOperationSucceeded), Ord(E.Kind));
  AssertEquals('Connect progress deduplicated', 1, FEvents.Count(lbekConnected, Id));
  AssertEquals(7, FEvents.Last(lbekConnected, Id).Generation);
end;

procedure TLazBleSimpleBleBackendTest.Shutdown;
var E: TLazBleBackendEvent;
begin
  E := Wait(FBackend.BeginShutdown);
  AssertEquals(Ord(lbekShutdownCompleted), Ord(E.Kind));
  AssertEquals(E.ErrorMessage, '', E.ErrorMessage);
end;

procedure TLazBleSimpleBleBackendTest.AvailabilityAndAdapterSelection;
var C: TLazBleBackendCommand; Id: TBleOperationId; E: TLazBleBackendEvent;
begin
  C := Request(lbckCheckAvailability);
  C.AdapterId := 'AA:BB:CC:DD:EE:FF';
  Id := FBackend.Submit(C);
  AssertEquals(0, Length(FEvents.Events));
  AssertEquals(Ord(lbekOperationSucceeded), Ord(Wait(Id).Kind));
  E := FEvents.Last(lbekAvailabilityResult, Id);
  AssertTrue(E.Available);
  AssertEquals('1.3.0', E.BackendVersion);
  AssertEquals('Plain Adapter', E.AdapterId);
end;

procedure TLazBleSimpleBleBackendTest.MissingAdapterIsAsyncFailure;
var C: TLazBleBackendCommand; E: TLazBleBackendEvent;
begin
  C := Request(lbckCheckAvailability); C.AdapterId := 'missing';
  E := Wait(FBackend.Submit(C));
  AssertEquals(Ord(lbekOperationFailed), Ord(E.Kind));
  AssertEquals(LazBleErrorAdapterNotFound, E.ErrorCode);
end;

procedure TLazBleSimpleBleBackendTest.PoweredOffAdapterIsUnavailable;
var E: TLazBleBackendEvent;
begin
  TBleAdapter.GetAdapters[0].PowerOff;
  try
    E := Wait(Send(lbckCheckAvailability));
    AssertEquals(Ord(lbekOperationFailed), Ord(E.Kind));
    AssertEquals(LazBleErrorBluetoothDisabled, E.ErrorCode);
  finally TBleAdapter.GetAdapters[0].PowerOn; end;
end;

procedure TLazBleSimpleBleBackendTest.ScanUsesMainThreadEventsAndFinalSnapshot;
var Id: TBleOperationId; E: TLazBleBackendEvent;
begin
  Id := Send(lbckStartScan);
  AssertEquals(Ord(lbekOperationSucceeded), Ord(Wait(Id).Kind));
  AssertEquals(1, FEvents.Count(lbekScanStarted, Id));
  AssertEquals(1, FEvents.Count(lbekScanStopped, Id));
  E := FEvents.Last(lbekScanResult, Id);
  AssertEquals(Device, E.DeviceId);
  AssertEquals('Plain Peripheral', E.DeviceName);
end;

procedure TLazBleSimpleBleBackendTest.StopScanWakesWorker;
var C: TLazBleBackendCommand; ScanId, StopId: TBleOperationId;
begin
  C := Request(lbckStartScan); C.TimeoutMs := 0;
  ScanId := FBackend.Submit(C);
  WaitForEvent(lbekScanStarted);
  StopId := Send(lbckStopScan);
  AssertEquals(Ord(lbekOperationSucceeded), Ord(Wait(ScanId).Kind));
  AssertEquals(Ord(lbekOperationSucceeded), Ord(Wait(StopId).Kind));
end;

procedure TLazBleSimpleBleBackendTest.QueuedCancellationSkipsNativeCall;
var C: TLazBleBackendCommand; ScanId, ReadId: TBleOperationId;
begin
  C := Request(lbckStartScan); C.TimeoutMs := 0;
  ScanId := FBackend.Submit(C);
  WaitForEvent(lbekScanStarted);
  ReadId := Send(lbckRead);
  FBackend.Cancel(ReadId);
  FBackend.Cancel(ScanId);
  AssertEquals(Ord(lbekOperationCancelled), Ord(Wait(ScanId).Kind));
  AssertEquals(Ord(lbekOperationCancelled), Ord(Wait(ReadId).Kind));
  AssertEquals(0, FEvents.Count(lbekReadResult, ReadId));
end;

procedure TLazBleSimpleBleBackendTest.ConnectDiscoveryAndGatt;
var Id: TBleOperationId; E: TLazBleBackendEvent; C: TLazBleBackendCommand;
  S: TLazBleGattService; Ch: TLazBleGattCharacteristic; Found: Boolean;
begin
  Connect;
  Id := Send(lbckDiscoverServices); Wait(Id);
  E := FEvents.Last(lbekServicesDiscovered, Id);
  Found := False;
  for S in E.Services do
    if S.Uuid = TestService then
      for Ch in S.Characteristics do
        if Ch.Uuid = TestValue then
        begin
          Found := True;
          AssertTrue(Ch.CanRead and Ch.CanWriteRequest and Ch.CanWriteCommand and
            Ch.CanNotify and Ch.CanIndicate);
          AssertTrue(Length(Ch.Descriptors) > 0);
        end;
  AssertTrue('Public GATT records converted', Found);
  C := Request(lbckWrite); C.Value := TBytes.Create(0, 127, 128, 255);
  Id := FBackend.Submit(C); C.Value[0] := 44;
  AssertEquals(Ord(lbekOperationSucceeded), Ord(Wait(Id).Kind));
  Id := Send(lbckRead); Wait(Id); E := FEvents.Last(lbekReadResult, Id);
  AssertEquals(4, Length(E.Value)); AssertEquals(0, E.Value[0]); AssertEquals(255, E.Value[3]);
  C.WriteMode := lbwmCommand; C.Value := TBytes.Create(12, 34);
  AssertEquals(Ord(lbekOperationSucceeded), Ord(Wait(FBackend.Submit(C)).Kind));
  Id := Send(lbckRead); Wait(Id); E := FEvents.Last(lbekReadResult, Id);
  AssertEquals(2, Length(E.Value)); AssertEquals(12, E.Value[0]);
end;

procedure TLazBleSimpleBleBackendTest.NativeErrorZeroIsFailure;
var C: TLazBleBackendCommand; E: TLazBleBackendEvent;
begin
  Connect; C := Request(lbckRead); C.ServiceUuid := StringOfChar('x', 37);
  E := Wait(FBackend.Submit(C));
  AssertEquals(Ord(lbekOperationFailed), Ord(E.Kind));
  AssertEquals(Ord(ecInvalidArgument), E.ErrorCode);
  AssertTrue(E.ErrorMessage <> '');
end;

procedure TLazBleSimpleBleBackendTest.NativeAttErrorIsPreserved;
var C: TLazBleBackendCommand; E: TLazBleBackendEvent;
begin
  Connect; C := Request(lbckRead); C.CharacteristicUuid := ErrorValue;
  E := Wait(FBackend.Submit(C));
  AssertEquals(Ord(lbekOperationFailed), Ord(E.Kind));
  AssertEquals(Ord(ecOperationFailed), E.ErrorCode);
end;

procedure TLazBleSimpleBleBackendTest.NotificationAndUnsubscribe;
var C: TLazBleBackendCommand; Id: TBleOperationId; Sub: TBleSubscriptionId; N: Integer;
begin
  Connect; C := Request(lbckSubscribe); C.ServiceUuid := BatteryService; C.CharacteristicUuid := BatteryValue;
  Id := FBackend.Submit(C); AssertEquals(Ord(lbekOperationSucceeded), Ord(Wait(Id).Kind));
  Sub := FEvents.Last(lbekSubscribed, Id).SubscriptionId;
  AssertTrue(Sub <> 0); WaitForEvent(lbekNotification);
  AssertEquals(100, FEvents.Last(lbekNotification).Value[0]);
  AssertEquals(7, FEvents.Last(lbekNotification).Generation);
  C.Kind := lbckUnsubscribe; C.SubscriptionId := Sub;
  AssertEquals(Ord(lbekOperationSucceeded), Ord(Wait(FBackend.Submit(C)).Kind));
  N := FEvents.Count(lbekNotification); Pump(1200);
  AssertEquals('No values after unsubscribe', N, FEvents.Count(lbekNotification));
end;

procedure TLazBleSimpleBleBackendTest.DuplicateSubscriptionDoesNotReplaceHandler;
var Id: TBleOperationId; E: TLazBleBackendEvent;
begin
  Connect; Wait(Send(lbckSubscribe));
  Id := Send(lbckSubscribe); E := Wait(Id);
  AssertEquals(Ord(lbekOperationFailed), Ord(E.Kind));
  AssertEquals(LazBleErrorInvalidState, E.ErrorCode);
  WaitForEvent(lbekNotification);
end;

procedure TLazBleSimpleBleBackendTest.StartedConnectReportsActualOutcome;
var E: TLazBleBackendEvent;
begin
  FEvents.CancelOnConnect := FBackend;
  E := Wait(Send(lbckConnect));
  FEvents.CancelOnConnect := nil;
  AssertEquals(Ord(lbekOperationSucceeded), Ord(E.Kind));
end;

procedure TLazBleSimpleBleBackendTest.DisconnectAndReconnect;
var Id: TBleOperationId;
begin
  Connect; Wait(Send(lbckSubscribe)); WaitForEvent(lbekNotification);
  Id := Send(lbckDisconnect);
  AssertEquals(Ord(lbekOperationSucceeded), Ord(Wait(Id).Kind));
  AssertEquals(1, FEvents.Count(lbekDisconnected));
  Connect;
  AssertEquals(Ord(lbekOperationSucceeded), Ord(Wait(Send(lbckSubscribe)).Kind));
  WaitForEvent(lbekNotification, 2);
end;

procedure TLazBleSimpleBleBackendTest.ShutdownDrainsScanAndQueuedCommands;
var C: TLazBleBackendCommand; ScanId, ReadId: TBleOperationId; N: Integer;
begin
  C := Request(lbckStartScan); C.TimeoutMs := 0; ScanId := FBackend.Submit(C);
  WaitForEvent(lbekScanStarted); ReadId := Send(lbckRead);
  Shutdown;
  AssertEquals(Ord(lbekOperationCancelled), Ord(Wait(ScanId).Kind));
  AssertEquals(Ord(lbekOperationCancelled), Ord(Wait(ReadId).Kind));
  AssertEquals(QWord(0), QWord(FBackend.Submit(C)));
  N := Length(FEvents.Events); Pump(100); AssertEquals(N, Length(FEvents.Events));
end;

procedure TLazBleSimpleBleBackendTest.ShutdownCleansActiveSubscription;
var N: Integer;
begin
  Connect; Wait(Send(lbckSubscribe)); WaitForEvent(lbekNotification);
  Shutdown; N := Length(FEvents.Events); Pump(1200);
  AssertEquals(N, Length(FEvents.Events));
  AssertEquals(0, Length(TBleAdapter.GetAdapters[0].GetConnectedPeripherals));
end;

procedure TLazBleSimpleBleBackendTest.BackendCanBeRecreated;
var I: Integer;
begin
  for I := 1 to 3 do
  begin
    Connect; Wait(Send(lbckSubscribe)); Shutdown;
    FBackend.SetEventSink(nil); FBackend := nil;
    FEvents.Events := nil;
    FBackend := TLazBleSimpleBleBackend.Create; FBackend.SetEventSink(FSink);
  end;
end;

procedure TLazBleSimpleBleBackendTest.OnlyOneBackendOwnsNativeCallbacks;
var Other: ILazBleBackend; OtherSink: TNativeEventSink; Sink: ILazBleBackendEventSink;
  Id: TBleOperationId; Deadline: QWord;
begin
  Wait(Send(lbckCheckAvailability));
  Other := TLazBleSimpleBleBackend.Create; OtherSink := TNativeEventSink.Create; Sink := OtherSink;
  Other.SetEventSink(Sink);
  try
    Id := Other.Submit(Request(lbckCheckAvailability)); Deadline := GetTickCount64+8000;
    while not OtherSink.Terminal(Id) and (GetTickCount64 < Deadline) do CheckSynchronize(5);
    AssertEquals(LazBleErrorAdapterAlreadyActive, OtherSink.Last(lbekOperationFailed,Id).ErrorCode);
    Id := Other.BeginShutdown; Deadline := GetTickCount64+8000;
    while not OtherSink.Terminal(Id) and (GetTickCount64 < Deadline) do CheckSynchronize(5);
    AssertTrue(OtherSink.Terminal(Id));
    AssertEquals(Ord(lbekOperationSucceeded), Ord(Wait(Send(lbckCheckAvailability)).Kind));
  finally Other.SetEventSink(nil); Other := nil; Sink := nil; end;
end;

procedure TLazBleSimpleBleBackendTest.PublicApiRequiresMainThread;
var Worker: TWrongThreadCall;
begin
  Worker := TWrongThreadCall.Create(True); Worker.Backend := FBackend;
  try Worker.Start; Worker.WaitFor; AssertTrue(Worker.Rejected); finally Worker.Free; end;
end;

procedure TLazBleSimpleBleBackendTest.SinkCanBeDetached;
begin
  FBackend.SetEventSink(nil); Send(lbckCheckAvailability); Pump(100);
  AssertEquals(0, Length(FEvents.Events)); FBackend.SetEventSink(FSink);
end;

procedure TLazBleSimpleBleBackendTest.UnsubscribeAfterLinkLossRetiresHandler;
var Worker: TNativeDisconnect; Id: TBleOperationId; C: TLazBleBackendCommand;
  E: TLazBleBackendEvent; N: Integer;
begin
  Connect;
  Id := Send(lbckSubscribe); Wait(Id);
  C := Request(lbckUnsubscribe);
  C.SubscriptionId := FEvents.Last(lbekSubscribed, Id).SubscriptionId;
  WaitForEvent(lbekNotification);
  Worker := TNativeDisconnect.Create(True);
  Worker.Peer := TBleAdapter.GetAdapters[0].GetConnectedPeripherals[0];
  try Worker.Start; Worker.WaitFor; finally Worker.Free; end;
  WaitForEvent(lbekDisconnected);
  E := Wait(FBackend.Submit(C));
  AssertEquals(Ord(lbekOperationFailed), Ord(E.Kind));
  AssertEquals(Ord(ecPeripheralNotConnected), E.ErrorCode);
  N := FEvents.Count(lbekNotification); Pump(1100);
  AssertEquals(N, FEvents.Count(lbekNotification));
  Connect;
  AssertEquals(Ord(lbekOperationSucceeded), Ord(Wait(Send(lbckSubscribe)).Kind));
end;

procedure TLazBleSimpleBleBackendTest.FacadeAndBatteryProfileUseNativeBackend;
var Ble: TLazBle; Client: TBleClient; Battery: TBleBatteryProfile;
  Operation: IBleOperation; Deadline: QWord;
begin
  Shutdown;
  Ble := TLazBle.Create;
  try
    Client := Ble.CreateClient(Device);
    Battery := TBleBatteryProfile.Create; Client.AddProfile(Battery);
    Operation := Client.ConnectAsync;
    Deadline := GetTickCount64 + 8000;
    while (Operation.State = lbopPending) and (GetTickCount64 < Deadline) do CheckSynchronize(5);
    AssertEquals(Operation.ErrorMessage, Ord(lbopSucceeded), Ord(Operation.State));
    Deadline := GetTickCount64 + 8000;
    while (Battery.State <> lbgpsReady) and (GetTickCount64 < Deadline) do CheckSynchronize(5);
    AssertEquals('Profile ready', Ord(lbgpsReady), Ord(Battery.State));
    AssertEquals(100, Battery.LevelPercent);
    Operation := Ble.ShutdownAsync;
    Deadline := GetTickCount64 + 8000;
    while (Operation.State = lbopPending) and (GetTickCount64 < Deadline) do CheckSynchronize(5);
    AssertEquals(Operation.ErrorMessage, Ord(lbopSucceeded), Ord(Operation.State));
  finally Ble.Free; end;
end;

procedure TLazBleSimpleBleBackendTest.ShutdownWhileNativeConnectCompletes;
var Id: TBleOperationId;
begin
  FEvents.ShutdownBackend := FBackend; FEvents.ShutdownOn := lbekConnected;
  Id := Send(lbckConnect);
  AssertEquals(Ord(lbekOperationSucceeded), Ord(Wait(Id).Kind));
  Shutdown;
  FEvents.ShutdownBackend := nil;
  AssertEquals(0, Length(TBleAdapter.GetAdapters[0].GetConnectedPeripherals));
end;

procedure TLazBleSimpleBleBackendTest.ShutdownFromSubscribeCompletion;
var Id: TBleOperationId; N: Integer;
begin
  Connect;
  FEvents.ShutdownBackend := FBackend; FEvents.ShutdownOn := lbekSubscribed;
  Id := Send(lbckSubscribe);
  AssertEquals(Ord(lbekOperationSucceeded), Ord(Wait(Id).Kind));
  Shutdown;
  FEvents.ShutdownBackend := nil;
  N := Length(FEvents.Events); Pump(1100); AssertEquals(N, Length(FEvents.Events));
end;

procedure TLazBleSimpleBleBackendTest.NativeFacadeReconnectUsesMainThreadTimer;
var Ble: TLazBle; Client: TBleClient; Battery: TBleBatteryProfile;
  Op: IBleOperation; Deadline, Generation: QWord; Worker: TNativeDisconnect;
begin
  Shutdown; Ble := TLazBle.Create;
  try
    Client := Ble.CreateClient(Device); Battery := TBleBatteryProfile.Create; Client.AddProfile(Battery);
    Client.ReconnectOptions := TLazBleReconnectOptions.Create(10,20,2); Client.AutoReconnect := True;
    Op := Client.ConnectAsync; Deadline := GetTickCount64+8000;
    while (Op.State=lbopPending) and (GetTickCount64<Deadline) do CheckSynchronize(5);
    AssertEquals(Op.ErrorMessage,Ord(lbopSucceeded),Ord(Op.State));
    Generation := TClientGenerationAccess(Client).CurrentGeneration;
    Worker := TNativeDisconnect.Create(True);
    Worker.Peer := TBleAdapter.GetAdapters[0].GetConnectedPeripherals[0];
    try Worker.Start; Worker.WaitFor; finally Worker.Free; end;
    Deadline := GetTickCount64+8000;
    while ((Client.State<>lbcstReady) or
      (TClientGenerationAccess(Client).CurrentGeneration=Generation)) and
      (GetTickCount64<Deadline) do CheckSynchronize(5);
    AssertTrue('New session established',TClientGenerationAccess(Client).CurrentGeneration>Generation);
    AssertEquals(Ord(lbcstReady),Ord(Client.State)); AssertEquals(100,Battery.LevelPercent);
    Op := Ble.ShutdownAsync; Deadline := GetTickCount64+8000;
    while (Op.State=lbopPending) and (GetTickCount64<Deadline) do CheckSynchronize(5);
    AssertEquals(Op.ErrorMessage,Ord(lbopSucceeded),Ord(Op.State));
  finally Ble.Free; end;
end;

procedure TLazBleSimpleBleBackendTest.NativeSyncPumpsMainThreadEvents;
var Sync: TLazBleSync; Devices: TBleDeviceInfos; Client: TBleClient; Error: string;
begin
  Shutdown; Sync := TLazBleSync.Create;
  try
    AssertTrue(Error,Sync.Scan('',100,Devices,Error)); AssertTrue(Length(Devices)>0);
    Client := Sync.CreateClient(Device);
    AssertTrue(Error,Sync.Connect(Client,8000,Error));
    AssertTrue(Length(Client.Services)>0);
    AssertTrue(Error,Sync.Disconnect(Client,8000,Error));
    AssertTrue(Error,Sync.Shutdown(8000,Error));
  finally Sync.Free; end;
end;

initialization
  RegisterTest(TLazBleSimpleBleBackendTest);
end.
