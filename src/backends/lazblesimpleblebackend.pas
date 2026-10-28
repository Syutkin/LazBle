unit LazBleSimpleBleBackend;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, Contnrs, SimpleDelphiBLE,
  LazBleTypes, LazBleBackend;

type
  { Main-thread API. The application must pump CheckSynchronize (or the LCL
    loop), await BeginShutdown, and defer destruction from its own callbacks.
    SimpleDelphiBLE owns all native objects. One backend may use them at a time. }
  TLazBleSimpleBleBackend = class(TInterfacedObject, ILazBleBackend)
  private type
    TPeerContext = class
      Native: TBlePeripheral;
      DeviceId: string;
      Generation: QWord;
      ConnectId, DisconnectId: TBleOperationId;
      ConnectedReported, DisconnectedReported: Boolean;
    end;
    TSubscriptionContext = class
      Peer: TPeerContext;
      Id: TBleSubscriptionId;
      Generation: QWord;
      ServiceUuid, CharacteristicUuid: string;
      Active, Registered: Boolean;
    end;
    TCommand = class
      Id: TBleOperationId;
      Request: TLazBleBackendCommand;
      Cancelled: LongInt;
      Wake: TEvent;
      Adapter: TBleAdapter;
      AdapterId: string;
      NativePeer: TBlePeripheral;
      Peer: TPeerContext;
      Subscription: TSubscriptionContext;
      ResultEvent: TLazBleBackendEvent;
      HasResult, Success, WasCancelled: Boolean;
      ScanStarted, ScanStopped: Boolean;
      ScanResults: array of TBlePeripheral;
      ScanDevices: TBleDeviceInfos;
      ErrorCode: Integer;
      ErrorText: string;
      constructor Create;
      destructor Destroy; override;
    end;
    TCommandWorker = class(TThread)
    private
      FOwner: TLazBleSimpleBleBackend;
    protected
      procedure Execute; override;
    public
      constructor Create(AOwner: TLazBleSimpleBleBackend);
    end;
  private
    FLock: TCriticalSection;
    FWork: TEvent;
    FPending, FOperations: TList;
    FPeers, FSubscriptions: TObjectList;
    FWorker: TCommandWorker;
    FCurrent, FScan: TCommand;
    FAdapter: TBleAdapter;
    FSink: ILazBleBackendEventSink;
    FNextId: TBleOperationId;
    FNextSubscription: TBleSubscriptionId;
    FStopping: LongInt;
    FShutdownId: TBleOperationId;
    FShutdownDone: Boolean;
    FShutdownErrorCode: Integer;
    FShutdownError: string;
    procedure RequireMainThread;
    function Stopping: Boolean;
    function NewId: TBleOperationId;
    function Pop: TCommand;
    function FindPeer(Native: TBlePeripheral): TPeerContext; overload;
    function FindSubscription(Id: TBleSubscriptionId): TSubscriptionContext;
    procedure Deliver(const Event: TLazBleBackendEvent);
    function EventFor(Task: TCommand; Kind: TLazBleBackendEventKind): TLazBleBackendEvent;
    procedure PrepareOnMain;
    procedure CompleteOnMain;
    procedure ShutdownOnMain;
    procedure DetachCallbacks;
    procedure WorkerExecute;
    procedure ExecuteCommand(Task: TCommand);
    procedure Cleanup;
    procedure SelectAdapter(Task: TCommand);
    procedure ResolvePeer(Task: TCommand);
    procedure RetireSubscriptions(Peer: TPeerContext);
    procedure RunScan(Task: TCommand);
    procedure ScanStart(Sender: TBleAdapter);
    procedure ScanStop(Sender: TBleAdapter);
    procedure ScanFound(Sender: TBleAdapter; Peripheral: TBlePeripheral);
    procedure Connected(Sender: TBlePeripheral);
    procedure Disconnected(Sender: TBlePeripheral);
    procedure ValueReceived(Sender: TBlePeripheral;
      const Service, Characteristic: UnicodeString; const Data: TBytes);
    procedure ReportPeer(Peer: TPeerContext; IsConnected: Boolean);
  public
    constructor Create;
    destructor Destroy; override;
    function GetBackendName: string;
    procedure SetEventSink(const AEventSink: ILazBleBackendEventSink);
    function Submit(const ACommand: TLazBleBackendCommand): TBleOperationId;
    procedure Cancel(const AOperationId: TBleOperationId);
    function BeginShutdown: TBleOperationId;
  end;

implementation

type
  EBackendError = class(Exception)
    Code: Integer;
    constructor Create(ACode: Integer; const Text: string);
  end;

var
  ActiveBackend: TLazBleSimpleBleBackend;

constructor EBackendError.Create(ACode: Integer; const Text: string);
begin
  inherited Create(Text);
  Code := ACode;
end;

function CopyServices(const Native: array of TBleService): TLazBleGattServices;
var
  I, J, K: Integer;
  C: TBleCharacteristic;
begin
  { Temporary boundary for the existing core records; removed in stage 3. }
  Result := nil;
  SetLength(Result, Length(Native));
  for I := 0 to High(Native) do
  begin
    Result[I].Uuid := UTF8Encode(Native[I].Uuid);
    Result[I].Data := Copy(Native[I].Data);
    SetLength(Result[I].Characteristics, Length(Native[I].Characteristics));
    for J := 0 to High(Native[I].Characteristics) do
    begin
      C := Native[I].Characteristics[J];
      with Result[I].Characteristics[J] do
      begin
        Uuid := UTF8Encode(C.Uuid);
        if C.CanRead then Include(Properties, lbgcpRead);
        if C.CanWriteRequest then Include(Properties, lbgcpWriteRequest);
        if C.CanWriteCommand then Include(Properties, lbgcpWriteCommand);
        if C.CanNotify then Include(Properties, lbgcpNotify);
        if C.CanIndicate then Include(Properties, lbgcpIndicate);
        SetLength(Descriptors, Length(C.Descriptors));
        for K := 0 to High(C.Descriptors) do
          Descriptors[K].Uuid := UTF8Encode(C.Descriptors[K]);
      end;
    end;
  end;
end;

constructor TLazBleSimpleBleBackend.TCommand.Create;
begin
  inherited Create;
  Wake := TEvent.Create(nil, True, False, '');
end;

destructor TLazBleSimpleBleBackend.TCommand.Destroy;
begin
  Wake.Free;
  inherited Destroy;
end;

constructor TLazBleSimpleBleBackend.TCommandWorker.Create(AOwner: TLazBleSimpleBleBackend);
begin
  inherited Create(True);
  FOwner := AOwner;
  Start;
end;

procedure TLazBleSimpleBleBackend.TCommandWorker.Execute;
begin
  FOwner.WorkerExecute;
end;

constructor TLazBleSimpleBleBackend.Create;
begin
  inherited Create;
  RequireMainThread;
  FLock := TCriticalSection.Create;
  FWork := TEvent.Create(nil, False, False, '');
  FPending := TList.Create;
  FOperations := TList.Create;
  FPeers := TObjectList.Create(True);
  FSubscriptions := TObjectList.Create(True);
  TSimpleDelphiBLE.EventDelivery := edMainThread;
  FWorker := TCommandWorker.Create(Self);
end;

destructor TLazBleSimpleBleBackend.Destroy;
begin
  if FWorker = nil then
  begin
    FSubscriptions.Free;
    FPeers.Free;
    FOperations.Free;
    FPending.Free;
    FWork.Free;
    FLock.Free;
    inherited Destroy;
    Exit;
  end;
  RequireMainThread;
  FSink := nil;
  { Safety fallback for idle clients and legacy owners. Normal GUI teardown
    awaits BeginShutdown; a native call can make this fallback block. }
  BeginShutdown;
  while not FShutdownDone do
    CheckSynchronize(10);
  FWorker.WaitFor;
  TThread.RemoveQueuedEvents(FWorker);
  FWorker.Free;
  FSubscriptions.Free;
  FPeers.Free;
  FOperations.Free;
  FPending.Free;
  FWork.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TLazBleSimpleBleBackend.RequireMainThread;
begin
  if GetCurrentThreadID <> MainThreadID then
    raise EInvalidOperation.Create('SimpleDelphiBLE backend requires the main thread');
end;

function TLazBleSimpleBleBackend.Stopping: Boolean;
begin
  Result := InterlockedCompareExchange(FStopping, 0, 0) <> 0;
end;

function TLazBleSimpleBleBackend.NewId: TBleOperationId;
begin
  Inc(FNextId);
  Result := FNextId;
end;

function TLazBleSimpleBleBackend.GetBackendName: string;
begin
  Result := 'SimpleBLE';
end;

procedure TLazBleSimpleBleBackend.SetEventSink(const AEventSink: ILazBleBackendEventSink);
begin
  RequireMainThread;
  FSink := AEventSink;
end;

function TLazBleSimpleBleBackend.FindPeer(Native: TBlePeripheral): TPeerContext;
var
  I: Integer;
begin
  for I := 0 to FPeers.Count - 1 do
    if TPeerContext(FPeers[I]).Native = Native then
      Exit(TPeerContext(FPeers[I]));
  Result := nil;
end;

function TLazBleSimpleBleBackend.FindSubscription(Id: TBleSubscriptionId): TSubscriptionContext;
var
  I: Integer;
begin
  for I := 0 to FSubscriptions.Count - 1 do
    if TSubscriptionContext(FSubscriptions[I]).Id = Id then
      Exit(TSubscriptionContext(FSubscriptions[I]));
  Result := nil;
end;

function TLazBleSimpleBleBackend.Submit(const ACommand: TLazBleBackendCommand): TBleOperationId;
var
  Task: TCommand;
  I: Integer;
begin
  RequireMainThread;
  if Stopping then Exit(InvalidBleOperationId);
  Task := TCommand.Create;
  Task.Id := NewId;
  Task.Request := ACommand;
  Task.Request.Value := Copy(ACommand.Value);
  if ActiveBackend = nil then ActiveBackend := Self;
  if ActiveBackend <> Self then
  begin
    Task.ErrorCode := LazBleErrorAdapterAlreadyActive;
    Task.ErrorText := 'Another LazBle SimpleDelphiBLE backend is active';
  end;
  { StopScan is a control request: wake the running scan before enqueueing its
    own completion. It does not call a blocking native method on the main thread. }
  if ACommand.Kind = lbckStopScan then
    for I := 0 to FOperations.Count - 1 do
      if TCommand(FOperations[I]).Request.Kind = lbckStartScan then
      begin
        TCommand(FOperations[I]).Wake.SetEvent;
      end;
  FOperations.Add(Task);
  FLock.Enter;
  try
    FPending.Add(Task);
  finally
    FLock.Leave;
  end;
  Result := Task.Id;
  FWork.SetEvent;
end;

procedure TLazBleSimpleBleBackend.Cancel(const AOperationId: TBleOperationId);
var
  I: Integer;
  Task: TCommand;
begin
  RequireMainThread;
  for I := 0 to FOperations.Count - 1 do
  begin
    Task := TCommand(FOperations[I]);
    if Task.Id = AOperationId then
    begin
      InterlockedExchange(Task.Cancelled, 1);
      Task.Wake.SetEvent;
      Exit;
    end;
  end;
end;

function TLazBleSimpleBleBackend.BeginShutdown: TBleOperationId;
var
  I: Integer;
begin
  RequireMainThread;
  if not Stopping then
  begin
    FShutdownId := NewId;
    InterlockedExchange(FStopping, 1);
    DetachCallbacks;
    for I := 0 to FOperations.Count - 1 do
      Cancel(TCommand(FOperations[I]).Id);
    FWork.SetEvent;
  end;
  Result := FShutdownId;
end;

procedure TLazBleSimpleBleBackend.Deliver(const Event: TLazBleBackendEvent);
var
  Sink: ILazBleBackendEventSink;
begin
  Sink := FSink;
  if Sink <> nil then
    try
      Sink.HandleBackendEvent(Event);
    except
      { A user handler must not terminate the command worker or strand shutdown. }
      try
        if Assigned(ApplicationHandleException) then ApplicationHandleException(nil)
        else ShowException(ExceptObject, ExceptAddr);
      except
        { As in the upstream dispatcher, an exception in the last-resort
          reporter cannot be reported to another application handler. }
      end;
    end;
end;

function TLazBleSimpleBleBackend.EventFor(Task: TCommand;
  Kind: TLazBleBackendEventKind): TLazBleBackendEvent;
begin
  Result := Default(TLazBleBackendEvent);
  Result.Kind := Kind;
  Result.OperationId := Task.Id;
  Result.Generation := Task.Request.Generation;
  Result.BackendName := GetBackendName;
  Result.DeviceId := Task.Request.DeviceId;
  Result.ServiceUuid := Task.Request.ServiceUuid;
  Result.CharacteristicUuid := Task.Request.CharacteristicUuid;
  Result.SubscriptionId := Task.Request.SubscriptionId;
  Result.AdapterId := Task.AdapterId;
end;

function TLazBleSimpleBleBackend.Pop: TCommand;
begin
  FLock.Enter;
  try
    Result := nil;
    if FPending.Count > 0 then
    begin
      Result := TCommand(FPending[0]);
      FPending.Delete(0);
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TLazBleSimpleBleBackend.PrepareOnMain;
var
  I: Integer;
  Sub: TSubscriptionContext;
begin
  if Stopping then
  begin
    FCurrent.WasCancelled := True;
    Exit;
  end;
  if (FAdapter <> nil) and (FAdapter <> FCurrent.Adapter) then
    raise EBackendError.Create(LazBleErrorAdapterAlreadyActive,
      'A backend uses one adapter until shutdown');
  FAdapter := FCurrent.Adapter;
  FAdapter.OnScanStart := @ScanStart;
  FAdapter.OnScanStop := @ScanStop;
  FAdapter.OnScanFound := @ScanFound;
  FAdapter.OnScanUpdated := @ScanFound;
  if FCurrent.Request.Kind in [lbckStartScan, lbckConnect] then
    FScan := FCurrent;
  if FCurrent.NativePeer = nil then Exit;
  FCurrent.Peer := FindPeer(FCurrent.NativePeer);
  if FCurrent.Peer = nil then
  begin
    FCurrent.Peer := TPeerContext.Create;
    FCurrent.Peer.Native := FCurrent.NativePeer;
    FCurrent.Peer.DeviceId := FCurrent.Request.DeviceId;
    FPeers.Add(FCurrent.Peer);
  end;
  FCurrent.NativePeer.OnConnected := @Connected;
  FCurrent.NativePeer.OnDisconnected := @Disconnected;
  if FCurrent.Request.Kind = lbckConnect then
  begin
    FCurrent.Peer.Generation := FCurrent.Request.Generation;
    FCurrent.Peer.ConnectId := FCurrent.Id;
    FCurrent.Peer.DisconnectId := InvalidBleOperationId;
    FCurrent.Peer.ConnectedReported := False;
    FCurrent.Peer.DisconnectedReported := False;
  end;
  if FCurrent.Request.Kind = lbckDisconnect then
    FCurrent.Peer.DisconnectId := FCurrent.Id;
  if FCurrent.Request.Kind = lbckSubscribe then
  begin
    for I := FSubscriptions.Count - 1 downto 0 do
    begin
      Sub := TSubscriptionContext(FSubscriptions[I]);
      if (Sub.Peer = FCurrent.Peer) and
        SameText(Sub.ServiceUuid, FCurrent.Request.ServiceUuid) and
        SameText(Sub.CharacteristicUuid, FCurrent.Request.CharacteristicUuid) then
        if Sub.Active or Sub.Registered then
          raise EBackendError.Create(LazBleErrorInvalidState,
            'Characteristic already has a subscription')
        else FSubscriptions.Delete(I);
    end;
    Sub := TSubscriptionContext.Create;
    Inc(FNextSubscription);
    Sub.Id := FNextSubscription;
    Sub.Peer := FCurrent.Peer;
    Sub.Generation := FCurrent.Request.Generation;
    Sub.ServiceUuid := LowerCase(FCurrent.Request.ServiceUuid);
    Sub.CharacteristicUuid := LowerCase(FCurrent.Request.CharacteristicUuid);
    FSubscriptions.Add(Sub);
    FCurrent.Subscription := Sub;
  end;
  if FCurrent.Request.Kind = lbckUnsubscribe then
  begin
    Sub := FindSubscription(FCurrent.Request.SubscriptionId);
    if (Sub = nil) or (Sub.Peer <> FCurrent.Peer) then
      raise EBackendError.Create(LazBleErrorSubscriptionNotKnown, 'Unknown subscription');
    Sub.Active := False;
    FCurrent.Subscription := Sub;
  end;
end;

procedure TLazBleSimpleBleBackend.RetireSubscriptions(Peer: TPeerContext);
var
  I: Integer;
  Sub: TSubscriptionContext;
begin
  { The worker owns registration changes; main-thread callbacks only retire
    delivery. Upstream removes its handler even if a disconnected peer rejects
    the native unsubscribe. }
  for I := 0 to FSubscriptions.Count - 1 do
  begin
    Sub := TSubscriptionContext(FSubscriptions[I]);
    if (Sub.Peer = Peer) and Sub.Registered then
      try
        try
          Sub.Peer.Native.Unsubscribe(UTF8Decode(Sub.ServiceUuid),
            UTF8Decode(Sub.CharacteristicUuid));
        except
          on E: EBleNotConnected do ;
        end;
      finally
        Sub.Registered := False;
      end;
  end;
end;

procedure TLazBleSimpleBleBackend.SelectAdapter(Task: TCommand);
var
  Adapters: array of TBleAdapter;
  Adapter: TBleAdapter;
begin
  Adapters := SimpleDelphiBLE.TBleBackend.GetNative.GetAdapters;
  if Length(Adapters) = 0 then
    raise EBackendError.Create(LazBleErrorNoAdapter, 'No Bluetooth adapter');
  for Adapter in Adapters do
    if (Task.Request.AdapterId = '') or
      SameText(Task.Request.AdapterId, UTF8Encode(Adapter.Identifier)) or
      SameText(Task.Request.AdapterId, UTF8Encode(Adapter.Address)) then
    begin
      Task.Adapter := Adapter;
      Task.AdapterId := UTF8Encode(Adapter.Identifier);
      Break;
    end;
  if Task.Adapter = nil then
    raise EBackendError.Create(LazBleErrorAdapterNotFound, 'Bluetooth adapter not found');
  TThread.Synchronize(FWorker, @PrepareOnMain);
  if not Task.Adapter.IsPowered then
    raise EBackendError.Create(LazBleErrorBluetoothDisabled, 'Bluetooth adapter is powered off');
end;

procedure TLazBleSimpleBleBackend.RunScan(Task: TCommand);
var
  Timeout: Cardinal;
  I: Integer;
begin
  Timeout := Task.Request.TimeoutMs;
  if (Task.Request.Kind = lbckConnect) and (Timeout = 0) then Timeout := 5000;
  if Timeout = 0 then Timeout := INFINITE;
  Task.Adapter.ScanStart;
  try
    Task.Wake.WaitFor(Timeout);
  finally
    Task.Adapter.ScanStop;
  end;
  Task.ScanResults := Task.Adapter.ScanGetResults;
  if Task.Request.Kind = lbckStartScan then
  begin
    SetLength(Task.ScanDevices, Length(Task.ScanResults));
    for I := 0 to High(Task.ScanResults) do
    begin
      Task.ScanDevices[I].DeviceId := UTF8Encode(Task.ScanResults[I].Address);
      Task.ScanDevices[I].DeviceName := UTF8Encode(Task.ScanResults[I].Identifier);
      Task.ScanDevices[I].Rssi := Task.ScanResults[I].Rssi;
    end;
  end;
end;

procedure TLazBleSimpleBleBackend.ResolvePeer(Task: TCommand);

  function Lookup(const Peers: array of TBlePeripheral): TBlePeripheral;
  var
    Peer: TBlePeripheral;
  begin
    for Peer in Peers do
      if SameText(UTF8Encode(Peer.Address), Task.Request.DeviceId) then Exit(Peer);
    Result := nil;
  end;

begin
  Task.NativePeer := Lookup(Task.Adapter.ScanGetResults);
  if Task.NativePeer = nil then
    Task.NativePeer := Lookup(Task.Adapter.GetConnectedPeripherals);
  if Task.NativePeer = nil then
    Task.NativePeer := Lookup(Task.Adapter.GetPairedPeripherals);
  if (Task.NativePeer = nil) and (Task.Request.Kind = lbckConnect) then
  begin
    RunScan(Task);
    Task.NativePeer := Lookup(Task.ScanResults);
  end;
  if (InterlockedCompareExchange(Task.Cancelled, 0, 0) <> 0) or Stopping then
  begin
    Task.WasCancelled := True;
    Exit;
  end;
  if Task.NativePeer = nil then
    raise EBackendError.Create(LazBleErrorDeviceNotFound, 'Bluetooth peripheral not found');
  TThread.Synchronize(FWorker, @PrepareOnMain);
end;

procedure TLazBleSimpleBleBackend.ExecuteCommand(Task: TCommand);
var
  Service, Characteristic: UnicodeString;
begin
  if Task.ErrorText <> '' then Exit;
  SelectAdapter(Task);
  if Stopping or (InterlockedCompareExchange(Task.Cancelled, 0, 0) <> 0) then
  begin
    Task.WasCancelled := True;
    Exit;
  end;
  Task.ResultEvent := EventFor(Task, lbekOperationSucceeded);
  if Task.Request.Kind = lbckCheckAvailability then
  begin
    Task.ResultEvent.Kind := lbekAvailabilityResult;
    Task.ResultEvent.Available := True;
    Task.ResultEvent.BackendVersion := UTF8Encode(TSimpleDelphiBLE.Version);
    Task.HasResult := True;
  end
  else if Task.Request.Kind = lbckStartScan then
  begin
    RunScan(Task);
    Task.WasCancelled := InterlockedCompareExchange(Task.Cancelled, 0, 0) <> 0;
  end
  else if Task.Request.Kind <> lbckStopScan then
  begin
    ResolvePeer(Task);
    if Task.WasCancelled then Exit;
    { Upstream subscription keys are case-sensitive. Use the same spelling for
      Notify, value routing and Unsubscribe, including uppercase profile UUIDs. }
    Service := UTF8Decode(LowerCase(Task.Request.ServiceUuid));
    Characteristic := UTF8Decode(LowerCase(Task.Request.CharacteristicUuid));
    case Task.Request.Kind of
      lbckConnect:
        begin
          RetireSubscriptions(Task.Peer);
          Task.NativePeer.Connect;
        end;
      lbckDisconnect:
        begin
          RetireSubscriptions(Task.Peer);
          Task.NativePeer.Disconnect;
        end;
      lbckDiscoverServices:
        begin
          Task.ResultEvent.Kind := lbekServicesDiscovered;
          Task.ResultEvent.Services := CopyServices(Task.NativePeer.Services);
          Task.HasResult := True;
        end;
      lbckRead:
        begin
          Task.ResultEvent.Kind := lbekReadResult;
          Task.ResultEvent.Value := Task.NativePeer.Read(Service, Characteristic);
          Task.HasResult := True;
        end;
      lbckWrite:
        begin
          if Task.Request.WriteMode = lbwmCommand then
            Task.NativePeer.WriteCommand(Service, Characteristic, Task.Request.Value)
          else Task.NativePeer.WriteRequest(Service, Characteristic, Task.Request.Value);
          Task.ResultEvent.Kind := lbekWriteCompleted;
          Task.HasResult := True;
        end;
      lbckSubscribe:
        begin
          Task.NativePeer.Notify(Service, Characteristic, @ValueReceived);
          Task.Subscription.Registered := True;
          Task.ResultEvent.Kind := lbekSubscribed;
          Task.ResultEvent.SubscriptionId := Task.Subscription.Id;
          Task.HasResult := True;
        end;
      lbckUnsubscribe:
        begin
          try
            Task.NativePeer.Unsubscribe(UTF8Decode(Task.Subscription.ServiceUuid),
              UTF8Decode(Task.Subscription.CharacteristicUuid));
          finally
            { Upstream removes the value handler even when native unsubscribe fails. }
            Task.Subscription.Registered := False;
          end;
          Task.ResultEvent.Kind := lbekUnsubscribed;
          Task.HasResult := True;
        end;
    else
      raise EBackendError.Create(LazBleErrorCommandNotImplemented, 'Unsupported BLE command');
    end;
  end;
  Task.Success := True;
end;

procedure TLazBleSimpleBleBackend.CompleteOnMain;
var
  Task: TCommand;
  Event: TLazBleBackendEvent;
  Device: TBleDeviceInfo;
begin
  Task := FCurrent;
  FOperations.Remove(Task);
  if FScan = Task then
  begin
    if (Task.Request.Kind = lbckStartScan) and not Stopping then
    begin
      { Merge the public final snapshot: a callback queued by upstream may not
        have reached the main loop before the command returned. }
      for Device in Task.ScanDevices do
      begin
        if Stopping then Break;
        ScanStart(Task.Adapter);
        if Stopping then Break;
        Event := EventFor(Task, lbekScanResult);
        Event.DeviceId := Device.DeviceId;
        Event.DeviceName := Device.DeviceName;
        Event.Rssi := Device.Rssi;
        Deliver(Event);
      end;
      if (Task.Success or Task.WasCancelled) and Task.ScanStarted and
        not Task.ScanStopped then ScanStop(Task.Adapter);
    end;
    FScan := nil;
  end;
  if not Stopping then
  begin
    if Task.Success and (Task.Request.Kind = lbckConnect) then
      if not Task.Peer.DisconnectedReported then ReportPeer(Task.Peer, True);
    if Task.Success and (Task.Request.Kind = lbckDisconnect) then
      ReportPeer(Task.Peer, False);
    if Task.Success and (Task.Subscription <> nil) and
      (Task.Request.Kind = lbckSubscribe) then Task.Subscription.Active := True;
    if Task.HasResult and Task.Success then Deliver(Task.ResultEvent);
  end;
  if (Task.Subscription <> nil) and
    ((Task.Request.Kind = lbckUnsubscribe) or
      ((Task.Request.Kind = lbckSubscribe) and not Task.Success)) then
    FSubscriptions.Remove(Task.Subscription);
  if Task.WasCancelled then Event := EventFor(Task, lbekOperationCancelled)
  else if Task.Success then Event := EventFor(Task, lbekOperationSucceeded)
  else
  begin
    Event := EventFor(Task, lbekOperationFailed);
    Event.ErrorCode := Task.ErrorCode;
    Event.ErrorMessage := Task.ErrorText;
  end;
  Deliver(Event);
end;

procedure TLazBleSimpleBleBackend.WorkerExecute;
begin
  repeat
    FCurrent := Pop;
    if FCurrent = nil then
    begin
      if Stopping then Break;
      FWork.WaitFor(INFINITE);
      Continue;
    end;
    try
      if Stopping or (InterlockedCompareExchange(FCurrent.Cancelled, 0, 0) <> 0) then
        FCurrent.WasCancelled := True
      else
        try
          ExecuteCommand(FCurrent);
        except
          on E: EBleError do
          begin
            FCurrent.ErrorCode := Ord(E.Code);
            FCurrent.ErrorText := E.Message;
          end;
          on E: EBackendError do
          begin
            FCurrent.ErrorCode := E.Code;
            FCurrent.ErrorText := E.Message;
          end;
          on E: Exception do
          begin
            FCurrent.ErrorCode := LazBleErrorBackendUnavailable;
            FCurrent.ErrorText := E.Message;
          end;
        end;
      TThread.Synchronize(FWorker, @CompleteOnMain);
    finally
      FreeAndNil(FCurrent);
    end;
  until False;
  Cleanup;
  { This is the last action: shutdown notification may release the backend.
    Its main-thread handler joins this worker before notifying the application. }
  TThread.Queue(FWorker, @ShutdownOnMain);
end;

procedure TLazBleSimpleBleBackend.ScanStart(Sender: TBleAdapter);
begin
  if Stopping or (FScan = nil) or (FScan.Adapter <> Sender) then Exit;
  if FScan.Request.Kind <> lbckStartScan then Exit;
  if FScan.ScanStarted then Exit;
  FScan.ScanStarted := True;
  Deliver(EventFor(FScan, lbekScanStarted));
end;

procedure TLazBleSimpleBleBackend.ScanStop(Sender: TBleAdapter);
begin
  if Stopping or (FScan = nil) or (FScan.Adapter <> Sender) then Exit;
  if FScan.Request.Kind <> lbckStartScan then Exit;
  if FScan.ScanStopped then Exit;
  FScan.ScanStopped := True;
  FScan.Wake.SetEvent;
  Deliver(EventFor(FScan, lbekScanStopped));
end;

procedure TLazBleSimpleBleBackend.ScanFound(Sender: TBleAdapter; Peripheral: TBlePeripheral);
var
  Event: TLazBleBackendEvent;
begin
  if Stopping or (FScan = nil) or (FScan.Adapter <> Sender) then Exit;
  if FScan.Request.Kind = lbckConnect then
  begin
    if SameText(UTF8Encode(Peripheral.Address), FScan.Request.DeviceId) then
      FScan.Wake.SetEvent;
    Exit;
  end;
  ScanStart(Sender);
  if Stopping then Exit;
  Event := EventFor(FScan, lbekScanResult);
  Event.DeviceId := UTF8Encode(Peripheral.Address);
  Event.DeviceName := UTF8Encode(Peripheral.Identifier);
  Event.Rssi := Peripheral.Rssi;
  Deliver(Event);
end;

procedure TLazBleSimpleBleBackend.ReportPeer(Peer: TPeerContext; IsConnected: Boolean);
var
  Event: TLazBleBackendEvent;
  I: Integer;
begin
  if Peer = nil then Exit;
  Event := Default(TLazBleBackendEvent);
  if IsConnected then
  begin
    if Peer.ConnectedReported then Exit;
    Peer.ConnectedReported := True;
    Peer.DisconnectedReported := False;
    Event.Kind := lbekConnected;
    Event.OperationId := Peer.ConnectId;
  end
  else
  begin
    if Peer.DisconnectedReported then Exit;
    Peer.DisconnectedReported := True;
    Event.Kind := lbekDisconnected;
    Event.OperationId := Peer.DisconnectId;
    for I := 0 to FSubscriptions.Count - 1 do
      if TSubscriptionContext(FSubscriptions[I]).Peer = Peer then
        TSubscriptionContext(FSubscriptions[I]).Active := False;
  end;
  Event.DeviceId := Peer.DeviceId;
  Event.Generation := Peer.Generation;
  Event.BackendName := GetBackendName;
  Deliver(Event);
end;

procedure TLazBleSimpleBleBackend.Connected(Sender: TBlePeripheral);
begin
  if not Stopping then ReportPeer(FindPeer(Sender), True);
end;

procedure TLazBleSimpleBleBackend.Disconnected(Sender: TBlePeripheral);
var
  Peer: TPeerContext;
begin
  if Stopping then Exit;
  Peer := FindPeer(Sender);
  { A queued disconnect from the previous owner/session can reach a newly
    attached handler. A connection must first have been reported by this owner. }
  if (Peer <> nil) and Peer.ConnectedReported then ReportPeer(Peer, False);
end;

procedure TLazBleSimpleBleBackend.ValueReceived(Sender: TBlePeripheral;
  const Service, Characteristic: UnicodeString; const Data: TBytes);
var
  I: Integer;
  Sub: TSubscriptionContext;
  Event: TLazBleBackendEvent;
begin
  if Stopping then Exit;
  for I := 0 to FSubscriptions.Count - 1 do
  begin
    Sub := TSubscriptionContext(FSubscriptions[I]);
    if Sub.Active and (Sub.Peer.Native = Sender) and
      SameText(Sub.ServiceUuid, UTF8Encode(Service)) and
      SameText(Sub.CharacteristicUuid, UTF8Encode(Characteristic)) then
    begin
      Event := Default(TLazBleBackendEvent);
      Event.Kind := lbekNotification;
      Event.SubscriptionId := Sub.Id;
      Event.Generation := Sub.Generation;
      Event.DeviceId := Sub.Peer.DeviceId;
      Event.ServiceUuid := Sub.ServiceUuid;
      Event.CharacteristicUuid := Sub.CharacteristicUuid;
      Event.Value := Copy(Data);
      Deliver(Event);
      Exit;
    end;
  end;
end;

procedure TLazBleSimpleBleBackend.DetachCallbacks;
var
  I: Integer;
  Peer: TPeerContext;
begin
  if FAdapter <> nil then
  begin
    FAdapter.OnScanStart := nil;
    FAdapter.OnScanStop := nil;
    FAdapter.OnScanFound := nil;
    FAdapter.OnScanUpdated := nil;
  end;
  for I := 0 to FPeers.Count - 1 do
  begin
    Peer := TPeerContext(FPeers[I]);
    Peer.Native.OnConnected := nil;
    Peer.Native.OnDisconnected := nil;
  end;
  for I := 0 to FSubscriptions.Count - 1 do
    TSubscriptionContext(FSubscriptions[I]).Active := False;
end;

procedure TLazBleSimpleBleBackend.Cleanup;
var
  I: Integer;
  Sub: TSubscriptionContext;
  Peer: TPeerContext;

  procedure Remember(E: Exception);
  begin
    if FShutdownError <> '' then Exit;
    FShutdownError := E.Message;
    if E is EBleError then FShutdownErrorCode := Ord(EBleError(E).Code)
    else FShutdownErrorCode := LazBleErrorBackendUnavailable;
  end;

begin
  if FAdapter <> nil then
    try
      if FAdapter.ScanIsActive then FAdapter.ScanStop;
    except
      on E: Exception do Remember(E);
    end;
  for I := 0 to FSubscriptions.Count - 1 do
  begin
    Sub := TSubscriptionContext(FSubscriptions[I]);
    if Sub.Registered then
      try
        Sub.Peer.Native.Unsubscribe(UTF8Decode(Sub.ServiceUuid),
          UTF8Decode(Sub.CharacteristicUuid));
      except
        on E: Exception do Remember(E);
      end;
  end;
  for I := 0 to FPeers.Count - 1 do
  begin
    Peer := TPeerContext(FPeers[I]);
    try
      if Peer.Native.IsConnected then Peer.Native.Disconnect;
    except
      on E: Exception do Remember(E);
    end;
  end;
end;

procedure TLazBleSimpleBleBackend.ShutdownOnMain;
var
  Event: TLazBleBackendEvent;
begin
  FWorker.WaitFor;
  if ActiveBackend = Self then ActiveBackend := nil;
  FShutdownDone := True;
  Event := Default(TLazBleBackendEvent);
  Event.Kind := lbekShutdownCompleted;
  Event.OperationId := FShutdownId;
  Event.BackendName := GetBackendName;
  Event.ErrorCode := FShutdownErrorCode;
  Event.ErrorMessage := FShutdownError;
  Deliver(Event);
end;

end.
