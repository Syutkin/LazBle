unit LazBleSimpleBleBackend;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Contnrs, SimpleDelphiBLE,
  LazBleTypes, LazBleBackend, LazBleReconnect;

type
  { Main-thread API. Pump CheckSynchronize (or the LCL loop), await shutdown,
    and defer destruction from callbacks. Native objects belong to upstream. }
  TLazBleSimpleBleBackend = class(TInterfacedObject, ILazBleBackend)
  private type
    TPeerContext = class
      Owner: TLazBleSimpleBleBackend;
      Native: TBlePeripheral;
      DeviceId: string;
      Generation: QWord;
      ConnectId, DisconnectId: TBleOperationId;
      ConnectedReported, DisconnectedReported, NeedsDisconnect: Boolean;
      procedure Connected(Sender: TBlePeripheral);
      procedure Disconnected(Sender: TBlePeripheral);
    end;
    TSubscriptionContext = class
      Owner: TLazBleSimpleBleBackend;
      Peer: TPeerContext;
      Id: TBleSubscriptionId;
      Generation: QWord;
      ServiceUuid, CharacteristicUuid: string;
      Active, Registered: Boolean;
      procedure ValueReceived(Sender: TBlePeripheral;
        const Service, Characteristic: UnicodeString; const Data: TBytes);
    end;
    TCommandRole = (crRequest, crCleanup, crShutdown);
    TCommand = class
      Id: TBleOperationId;
      Request: TLazBleBackendCommand;
      Completion: ILazBleRequestCompletion;
      Role: TCommandRole;
      Parent: TCommand;
      Adapter: TBleAdapter;
      AdapterId: string;
      NativePeer: TBlePeripheral;
      Peer: TPeerContext;
      Subscription: TSubscriptionContext;
      ResultEvent: TLazBleBackendEvent;
      ScanDevices: TBleDeviceInfos;
      Cancelled, Prepared, HasResult, Failed: Boolean;
      ScanStarted, ScanStopped, StopRequested: Boolean;
      ErrorCode: Integer;
      ErrorText: string;
    end;
    { One background action for a synchronous public call or initial discovery
      lookup. Connected GATT commands go directly to upstream Async methods. }
    TMetadataWorker = class(TThread)
    private
      FOwner: TLazBleSimpleBleBackend;
      FTask: TCommand;
      FStopScan, FFailed: Boolean;
      FCode: Integer;
      FText: string;
      procedure Complete;
    protected
      procedure Execute; override;
    public
      constructor Create(AOwner: TLazBleSimpleBleBackend; AStopScan: Boolean);
    end;
  private
    FPending: TList;
    FPeers, FSubscriptions: TObjectList;
    FMetadata: TMetadataWorker;
    FCurrent, FScan: TCommand;
    FAdapter: TBleAdapter;
    FAdapterId: string;
    FSink: ILazBleBackendEventSink;
    FScanTimer: ILazBleReconnectTimer;
    FNextId: TBleOperationId;
    FNextSubscription: TBleSubscriptionId;
    FStopping, FDestroying, FQueued, FScanning: Boolean;
    FShutdownId: TBleOperationId;
    FShutdownDone, FShutdownFailed: Boolean;
    FShutdownErrorCode: Integer;
    FShutdownError: string;
    function Hold: ILazBleBackend;
    function NewId: TBleOperationId;
    function FindPeer(const DeviceId: string): TPeerContext;
    function FindSubscription(Id: TBleSubscriptionId): TSubscriptionContext;
    procedure Deliver(const Event: TLazBleBackendEvent);
    function EventFor(Task: TCommand; Kind: TLazBleBackendEventKind): TLazBleBackendEvent;
    procedure Schedule;
    procedure Pump;
    procedure BeginCommand;
    procedure StartMetadata(StopScan: Boolean = False);
    procedure RunMetadata(Worker: TMetadataWorker);
    procedure MetadataDone(Worker: TMetadataWorker);
    procedure PreparePeer;
    function QueueCleanup(Peer: TPeerContext; Parent: TCommand;
      InsertAt: Integer; Disconnect: Boolean): Integer;
    procedure QueueShutdown;
    procedure CompleteShutdown;
    procedure InvokeCurrent;
    procedure CommandDone(Sender: TObject; Error: Exception);
    procedure ReadDone(Sender: TBlePeripheral; const Data: TBytes; Error: Exception);
    procedure FinishCurrent(Kind: TLazBleBackendEventKind;
      Code: Integer = 0; const Text: string = '');
    procedure FailCurrent(Error: Exception);
    procedure StopCurrentScan;
    procedure ScanElapsed;
    procedure ScanStart(Sender: TBleAdapter);
    procedure ScanStop(Sender: TBleAdapter);
    procedure ScanFound(Sender: TBleAdapter; Peripheral: TBlePeripheral);
    procedure ReportPeer(Peer: TPeerContext; IsConnected: Boolean);
    procedure DetachCallbacks;
  public
    constructor Create;
    destructor Destroy; override;
    function GetBackendName: string;
    procedure SetEventSink(const AEventSink: ILazBleBackendEventSink);
    function Submit(const ACommand: TLazBleBackendCommand;
      const ACompletion: ILazBleRequestCompletion = nil): TBleOperationId;
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

function ErrorCode(Error: Exception): Integer;
begin
  if Error is EBleError then Result := Ord(EBleError(Error).Code)
  else if Error is EBackendError then Result := EBackendError(Error).Code
  else Result := LazBleErrorBackendUnavailable;
end;

constructor TLazBleSimpleBleBackend.TMetadataWorker.Create(
  AOwner: TLazBleSimpleBleBackend; AStopScan: Boolean);
begin
  inherited Create(True);
  FOwner := AOwner;
  FTask := AOwner.FCurrent;
  FStopScan := AStopScan;
  Start;
end;

procedure TLazBleSimpleBleBackend.TMetadataWorker.Execute;
begin
  try
    FOwner.RunMetadata(Self);
  except
    on E: Exception do
    begin
      FFailed := True;
      FCode := ErrorCode(E);
      FText := E.Message;
    end;
  end;
  TThread.ForceQueue(Self, @Complete);
end;

procedure TLazBleSimpleBleBackend.TMetadataWorker.Complete;
var
  KeepAlive: ILazBleBackend;
begin
  KeepAlive := FOwner.Hold;
  WaitFor;
  FOwner.FMetadata := nil;
  try
    FOwner.MetadataDone(Self);
  finally
    Free;
  end;
end;

constructor TLazBleSimpleBleBackend.Create;
begin
  inherited Create;
  LazBleRequireMainThread;
  FPending := TList.Create;
  FPeers := TObjectList.Create(True);
  FSubscriptions := TObjectList.Create(True);
  FScanTimer := LazBleCreateDefaultReconnectTimerFactory.CreateTimer;
  TSimpleDelphiBLE.EventDelivery := edMainThread;
end;

destructor TLazBleSimpleBleBackend.Destroy;
begin
  LazBleRequireMainThread;
  FDestroying := True;
  FSink := nil;
  BeginShutdown;
  while not FShutdownDone do CheckSynchronize(10);
  FScanTimer.Cancel;
  TThread.RemoveQueuedEvents(@Pump);
  FSubscriptions.Free;
  FPeers.Free;
  FPending.Free;
  inherited Destroy;
end;

function TLazBleSimpleBleBackend.Hold: ILazBleBackend;
begin
  Result := nil;
  if not FDestroying then Result := Self;
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
  LazBleRequireMainThread;
  FSink := AEventSink;
end;

function TLazBleSimpleBleBackend.FindPeer(const DeviceId: string): TPeerContext;
var
  I: Integer;
begin
  for I := 0 to FPeers.Count - 1 do
    if SameText(TPeerContext(FPeers[I]).DeviceId, DeviceId) then Exit(TPeerContext(FPeers[I]));
  Result := nil;
end;

function TLazBleSimpleBleBackend.FindSubscription(Id: TBleSubscriptionId): TSubscriptionContext;
var
  I: Integer;
begin
  for I := 0 to FSubscriptions.Count - 1 do
    if TSubscriptionContext(FSubscriptions[I]).Id = Id then Exit(TSubscriptionContext(FSubscriptions[I]));
  Result := nil;
end;

function TLazBleSimpleBleBackend.Submit(const ACommand: TLazBleBackendCommand;
  const ACompletion: ILazBleRequestCompletion): TBleOperationId;
var
  Task: TCommand;
  I: Integer;
begin
  LazBleRequireMainThread;
  if FStopping then Exit(InvalidBleOperationId);
  Task := TCommand.Create;
  Task.Id := NewId;
  Task.Request := ACommand;
  Task.Completion := ACompletion;
  Task.Request.Value := Copy(ACommand.Value);
  FPending.Add(Task);
  Result := Task.Id;
  if ACommand.Kind = lbckStopScan then
  begin
    for I := 0 to FPending.Count - 1 do
      if TCommand(FPending[I]).Request.Kind = lbckStartScan then
        TCommand(FPending[I]).StopRequested := True;
    if FScan <> nil then FScan.StopRequested := True;
    StopCurrentScan;
  end;
  Schedule;
end;

procedure TLazBleSimpleBleBackend.Cancel(const AOperationId: TBleOperationId);
var
  I: Integer;
  Task: TCommand;
begin
  LazBleRequireMainThread;
  if AOperationId = InvalidBleOperationId then Exit;
  if (FCurrent <> nil) and (FCurrent.Id = AOperationId) then
  begin
    FCurrent.Cancelled := True;
    if FScan = FCurrent then StopCurrentScan;
  end;
  for I := 0 to FPending.Count - 1 do
  begin
    Task := TCommand(FPending[I]);
    if Task.Id = AOperationId then Task.Cancelled := True;
  end;
end;

function TLazBleSimpleBleBackend.BeginShutdown: TBleOperationId;
begin
  LazBleRequireMainThread;
  if not FStopping then
  begin
    FStopping := True;
    FShutdownId := NewId;
    DetachCallbacks;
    if (FCurrent <> nil) and (FCurrent.Role = crRequest) then FCurrent.Cancelled := True;
    StopCurrentScan;
    Schedule;
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
      try
        if Assigned(ApplicationHandleException) then ApplicationHandleException(nil)
        else ShowException(ExceptObject, ExceptAddr);
      except
        { A failing user exception reporter must not strand shutdown. }
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
  Result.DescriptorUuid := Task.Request.DescriptorUuid;
  Result.SubscriptionId := Task.Request.SubscriptionId;
  Result.AdapterId := Task.AdapterId;
end;

procedure TLazBleSimpleBleBackend.Schedule;
begin
  if FQueued or FShutdownDone then Exit;
  FQueued := True;
  TThread.ForceQueue(nil, @Pump);
end;

procedure TLazBleSimpleBleBackend.Pump;
var
  KeepAlive: ILazBleBackend;
begin
  KeepAlive := Hold;
  FQueued := False;
  if FCurrent <> nil then Exit;
  if FPending.Count = 0 then
  begin
    if FStopping then QueueShutdown else Exit;
  end;
  FCurrent := TCommand(FPending[0]);
  FPending.Delete(0);
  if FCurrent.Role = crShutdown then CompleteShutdown
  else if (FCurrent.Role = crRequest) and (FStopping or FCurrent.Cancelled) then
    FinishCurrent(lbekOperationCancelled)
  else if FCurrent.Failed then
    FinishCurrent(lbekOperationFailed, FCurrent.ErrorCode, FCurrent.ErrorText)
  else if (ActiveBackend <> nil) and (ActiveBackend <> Self) then
    FinishCurrent(lbekOperationFailed, LazBleErrorAdapterAlreadyActive,
      'Another LazBle SimpleDelphiBLE backend is active')
  else
  begin
    ActiveBackend := Self;
    try
      BeginCommand;
    except
      on E: Exception do FailCurrent(E);
    end;
  end;
end;

procedure TLazBleSimpleBleBackend.BeginCommand;
var
  N: Integer;
begin
  FCurrent.Adapter := FAdapter;
  FCurrent.AdapterId := FAdapterId;
  FCurrent.ResultEvent := EventFor(FCurrent, lbekOperationSucceeded);
  if FCurrent.Role = crCleanup then
  begin
    if FCurrent.Request.Kind = lbckStopScan then StartMetadata
    else InvokeCurrent;
    Exit;
  end;
  if FCurrent.Request.Kind = lbckStopScan then
  begin
    FinishCurrent(lbekOperationSucceeded);
    Exit;
  end;
  if FCurrent.Request.Kind in [lbckCheckAvailability, lbckStartScan] then
  begin
    if FCurrent.Request.Kind = lbckStartScan then FScan := FCurrent;
    StartMetadata;
    Exit;
  end;
  if not FCurrent.Prepared then
  begin
    FCurrent.Peer := FindPeer(FCurrent.Request.DeviceId);
    if FCurrent.Peer = nil then
    begin
      if FCurrent.Request.Kind = lbckConnect then StartMetadata
      else raise EBackendError.Create(LazBleErrorDeviceNotKnown, 'Bluetooth peripheral is not known');
      Exit;
    end;
    PreparePeer;
    FCurrent.Prepared := True;
    if FCurrent.Request.Kind in [lbckConnect, lbckDisconnect] then
    begin
      N := QueueCleanup(FCurrent.Peer, FCurrent, 0, False);
      if N > 0 then
      begin
        FPending.Insert(N, FCurrent);
        FCurrent := nil;
        Schedule;
        Exit;
      end;
    end;
  end;
  if FCurrent.Request.Kind = lbckDiscoverServices then StartMetadata
  else InvokeCurrent;
end;

procedure TLazBleSimpleBleBackend.StartMetadata(StopScan: Boolean);
begin
  FMetadata := TMetadataWorker.Create(Self, StopScan);
end;

procedure TLazBleSimpleBleBackend.RunMetadata(Worker: TMetadataWorker);
var
  Task: TCommand;
  Adapter: TBleAdapter;
  Adapters: array of TBleAdapter;
  Peers: array of TBlePeripheral;
  I: Integer;

  function Lookup(const Items: array of TBlePeripheral): TBlePeripheral;
  var
    Peer: TBlePeripheral;
  begin
    for Peer in Items do
      if SameText(UTF8Encode(Peer.Address), Task.Request.DeviceId) then Exit(Peer);
    Result := nil;
  end;

begin
  Task := Worker.FTask;
  if (Task.Adapter = nil) or (Task.Request.Kind = lbckCheckAvailability) or
    (Task.Request.AdapterId <> '') then
  begin
    Task.Adapter := nil;
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
  end;
  case Task.Request.Kind of
    lbckCheckAvailability:
      begin
        if not Task.Adapter.IsPowered then
          raise EBackendError.Create(LazBleErrorBluetoothDisabled, 'Bluetooth adapter is powered off');
        Task.ResultEvent.BackendVersion := UTF8Encode(TSimpleDelphiBLE.Version);
        Task.ResultEvent.Kind := lbekAvailabilityResult;
        Task.ResultEvent.Available := True;
        Task.HasResult := True;
      end;
    lbckConnect:
      begin
        Task.NativePeer := Lookup(Task.Adapter.ScanGetResults);
        if Task.NativePeer = nil then Task.NativePeer := Lookup(Task.Adapter.GetConnectedPeripherals);
        if Task.NativePeer = nil then Task.NativePeer := Lookup(Task.Adapter.GetPairedPeripherals);
        if Task.NativePeer = nil then
          raise EBackendError.Create(LazBleErrorDeviceNotKnown, 'Peripheral is not known; scan before connecting');
      end;
    lbckDiscoverServices:
      begin
        Task.ResultEvent.Services := Task.Peer.Native.Services;
        Task.ResultEvent.Kind := lbekServicesDiscovered;
        Task.HasResult := True;
      end;
    lbckStartScan:
      if not Worker.FStopScan then Task.Adapter.ScanStart
      else
      begin
        Task.Adapter.ScanStop;
        Peers := Task.Adapter.ScanGetResults;
        SetLength(Task.ScanDevices, Length(Peers));
        for I := 0 to High(Peers) do
        begin
          Task.ScanDevices[I].DeviceId := UTF8Encode(Peers[I].Address);
          Task.ScanDevices[I].DeviceName := UTF8Encode(Peers[I].Identifier);
          Task.ScanDevices[I].Rssi := Peers[I].Rssi;
        end;
      end;
    lbckStopScan: if Task.Adapter.ScanIsActive then Task.Adapter.ScanStop;
  end;
end;

procedure TLazBleSimpleBleBackend.MetadataDone(Worker: TMetadataWorker);
var
  Task: TCommand;
  Device: TBleDeviceInfo;
  Event: TLazBleBackendEvent;
begin
  Task := FCurrent;
  try
    if (FAdapter <> nil) and (Task.Adapter <> nil) and (FAdapter <> Task.Adapter) then
      raise EBackendError.Create(LazBleErrorAdapterAlreadyActive, 'A backend uses one adapter until shutdown');
    if (FAdapter = nil) and (Task.Adapter <> nil) then
    begin
      FAdapter := Task.Adapter;
      FAdapterId := Task.AdapterId;
      if not FStopping then
      begin
        FAdapter.OnScanStart := @ScanStart;
        FAdapter.OnScanStop := @ScanStop;
        FAdapter.OnScanFound := @ScanFound;
        FAdapter.OnScanUpdated := @ScanFound;
      end;
    end;
    Task.ResultEvent.AdapterId := Task.AdapterId;
    if Worker.FFailed then
    begin
      if FScan = Task then
      begin
        FScanTimer.Cancel;
        FScanning := False;
      end;
      FinishCurrent(lbekOperationFailed, Worker.FCode, Worker.FText);
      Exit;
    end;
    if Task.Request.Kind = lbckStartScan then
    begin
      FScanning := not Worker.FStopScan;
      if not Worker.FStopScan then
      begin
        ScanStart(Task.Adapter);
        if FStopping or Task.Cancelled or Task.StopRequested then StopCurrentScan
        else if Task.Request.TimeoutMs > 0 then FScanTimer.Start(Task.Request.TimeoutMs, @ScanElapsed);
        Exit;
      end;
      FScanTimer.Cancel;
      for Device in Task.ScanDevices do
      begin
        if FStopping then Break;
        ScanStart(Task.Adapter);
        if FStopping then Break;
        Event := EventFor(Task, lbekScanResult);
        Event.DeviceId := Device.DeviceId;
        Event.DeviceName := Device.DeviceName;
        Event.Rssi := Device.Rssi;
        Deliver(Event);
      end;
      if not FStopping and Task.ScanStarted and not Task.ScanStopped then
      begin
        Task.ScanStopped := True;
        Deliver(EventFor(Task, lbekScanStopped));
      end;
      if FStopping or Task.Cancelled then FinishCurrent(lbekOperationCancelled)
      else FinishCurrent(lbekOperationSucceeded);
    end
    else if Task.Request.Kind = lbckConnect then
    begin
      if FStopping or Task.Cancelled then
      begin
        FinishCurrent(lbekOperationCancelled);
        Exit;
      end;
      Task.Peer := TPeerContext.Create;
      Task.Peer.Owner := Self;
      Task.Peer.Native := Task.NativePeer;
      Task.Peer.DeviceId := Task.Request.DeviceId;
      Task.Peer.Native.OnConnected := @Task.Peer.Connected;
      Task.Peer.Native.OnDisconnected := @Task.Peer.Disconnected;
      FPeers.Add(Task.Peer);
      BeginCommand;
    end
    else FinishCurrent(lbekOperationSucceeded);
  except
    on E: Exception do FailCurrent(E);
  end;
end;

procedure TLazBleSimpleBleBackend.PreparePeer;
var
  I: Integer;
  Sub: TSubscriptionContext;
begin
  if FCurrent.Request.Kind = lbckSubscribe then
  begin
    for I := FSubscriptions.Count - 1 downto 0 do
    begin
      Sub := TSubscriptionContext(FSubscriptions[I]);
      if (Sub.Peer = FCurrent.Peer) and
        SameText(Sub.ServiceUuid, FCurrent.Request.ServiceUuid) and
        SameText(Sub.CharacteristicUuid, FCurrent.Request.CharacteristicUuid) then
        if Sub.Active or Sub.Registered then
          raise EBackendError.Create(LazBleErrorInvalidState, 'Characteristic already has a subscription')
        else FSubscriptions.Delete(I);
    end;
    Sub := TSubscriptionContext.Create;
    Sub.Owner := Self;
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

function TLazBleSimpleBleBackend.QueueCleanup(Peer: TPeerContext; Parent: TCommand;
  InsertAt: Integer; Disconnect: Boolean): Integer;
var
  I: Integer;
  Sub: TSubscriptionContext;
  Task: TCommand;
begin
  Result := 0;
  for I := 0 to FSubscriptions.Count - 1 do
  begin
    Sub := TSubscriptionContext(FSubscriptions[I]);
    if (Sub.Peer <> Peer) or not Sub.Registered then Continue;
    Sub.Active := False;
    Task := TCommand.Create;
    Task.Role := crCleanup;
    Task.Parent := Parent;
    Task.Peer := Peer;
    Task.Subscription := Sub;
    Task.Request.Kind := lbckUnsubscribe;
    FPending.Insert(InsertAt + Result, Task);
    Inc(Result);
  end;
  if Disconnect and Peer.NeedsDisconnect then
  begin
    Task := TCommand.Create;
    Task.Role := crCleanup;
    Task.Peer := Peer;
    Task.Request.Kind := lbckDisconnect;
    FPending.Insert(InsertAt + Result, Task);
    Inc(Result);
  end;
end;

procedure TLazBleSimpleBleBackend.QueueShutdown;
var
  I: Integer;
  Task: TCommand;
begin
  if FAdapter <> nil then
  begin
    Task := TCommand.Create;
    Task.Role := crCleanup;
    Task.Request.Kind := lbckStopScan;
    FPending.Add(Task);
  end;
  for I := 0 to FPeers.Count - 1 do
    QueueCleanup(TPeerContext(FPeers[I]), nil, FPending.Count, True);
  Task := TCommand.Create;
  Task.Role := crShutdown;
  FPending.Add(Task);
end;

procedure TLazBleSimpleBleBackend.CompleteShutdown;
var
  Event: TLazBleBackendEvent;
begin
  FreeAndNil(FCurrent);
  FShutdownDone := True;
  if ActiveBackend = Self then ActiveBackend := nil;
  Event := Default(TLazBleBackendEvent);
  Event.Kind := lbekShutdownCompleted;
  Event.OperationId := FShutdownId;
  Event.BackendName := GetBackendName;
  Event.ShutdownFailed := FShutdownFailed;
  Event.ErrorCode := FShutdownErrorCode;
  Event.ErrorMessage := FShutdownError;
  Deliver(Event);
end;

procedure TLazBleSimpleBleBackend.InvokeCurrent;
var
  Service, Characteristic, Descriptor: UnicodeString;
  Peer: TPeerContext;
begin
  Peer := FCurrent.Peer;
  if FCurrent.Request.Kind = lbckConnect then
  begin
    Peer.Generation := FCurrent.Request.Generation;
    Peer.ConnectId := FCurrent.Id;
    Peer.DisconnectId := InvalidBleOperationId;
    Peer.ConnectedReported := False;
    Peer.DisconnectedReported := False;
    Peer.NeedsDisconnect := True;
  end;
  if FCurrent.Request.Kind = lbckDisconnect then Peer.DisconnectId := FCurrent.Id;
  Service := UTF8Decode(LowerCase(FCurrent.Request.ServiceUuid));
  Characteristic := UTF8Decode(LowerCase(FCurrent.Request.CharacteristicUuid));
  Descriptor := UTF8Decode(LowerCase(FCurrent.Request.DescriptorUuid));
  try
    case FCurrent.Request.Kind of
      lbckConnect: Peer.Native.ConnectAsync(@CommandDone);
      lbckDisconnect: Peer.Native.DisconnectAsync(@CommandDone);
      lbckRead: Peer.Native.ReadAsync(Service, Characteristic, @ReadDone);
      lbckReadDescriptor: Peer.Native.ReadDescriptorAsync(Service, Characteristic, Descriptor, @ReadDone);
      lbckWriteDescriptor: Peer.Native.WriteDescriptorAsync(Service, Characteristic, Descriptor,
        FCurrent.Request.Value, @CommandDone);
      lbckWrite:
        if FCurrent.Request.WriteMode = lbwmCommand then
          Peer.Native.WriteCommandAsync(Service, Characteristic, FCurrent.Request.Value, @CommandDone)
        else Peer.Native.WriteRequestAsync(Service, Characteristic, FCurrent.Request.Value, @CommandDone);
      lbckSubscribe:
        if FCurrent.Request.SubscriptionMode = lbsmIndicate then
          Peer.Native.IndicateAsync(Service, Characteristic, @FCurrent.Subscription.ValueReceived, @CommandDone)
        else Peer.Native.NotifyAsync(Service, Characteristic, @FCurrent.Subscription.ValueReceived, @CommandDone);
      lbckUnsubscribe: Peer.Native.UnsubscribeAsync(UTF8Decode(FCurrent.Subscription.ServiceUuid),
        UTF8Decode(FCurrent.Subscription.CharacteristicUuid), @CommandDone);
    else raise EBackendError.Create(LazBleErrorCommandNotImplemented, 'Unsupported BLE command');
    end;
  except
    on E: Exception do CommandDone(nil, E);
  end;
end;

procedure TLazBleSimpleBleBackend.ReadDone(Sender: TBlePeripheral;
  const Data: TBytes; Error: Exception);
begin
  FCurrent.ResultEvent.Value := Data;
  CommandDone(Sender, Error);
end;

procedure TLazBleSimpleBleBackend.CommandDone(Sender: TObject; Error: Exception);
var
  KeepAlive: ILazBleBackend;
begin
  KeepAlive := Hold;
  if FCurrent.Request.Kind = lbckUnsubscribe then FCurrent.Subscription.Registered := False;
  if Error <> nil then
  begin
    FailCurrent(Error);
    Exit;
  end;
  case FCurrent.Request.Kind of
    lbckDisconnect: FCurrent.Peer.NeedsDisconnect := False;
    lbckRead, lbckReadDescriptor: FCurrent.ResultEvent.Kind := lbekReadResult;
    lbckWrite, lbckWriteDescriptor: FCurrent.ResultEvent.Kind := lbekWriteCompleted;
    lbckSubscribe:
      begin
        FCurrent.Subscription.Registered := True;
        FCurrent.Subscription.Active := not FStopping;
        FCurrent.ResultEvent.Kind := lbekSubscribed;
        FCurrent.ResultEvent.SubscriptionId := FCurrent.Subscription.Id;
      end;
    lbckUnsubscribe: FCurrent.ResultEvent.Kind := lbekUnsubscribed;
  end;
  FCurrent.HasResult := FCurrent.Request.Kind in [lbckRead, lbckWrite,
    lbckReadDescriptor, lbckWriteDescriptor, lbckSubscribe, lbckUnsubscribe];
  FinishCurrent(lbekOperationSucceeded);
end;

procedure TLazBleSimpleBleBackend.FailCurrent(Error: Exception);
begin
  FinishCurrent(lbekOperationFailed, ErrorCode(Error), Error.Message);
end;

procedure TLazBleSimpleBleBackend.FinishCurrent(Kind: TLazBleBackendEventKind;
  Code: Integer; const Text: string);
var
  Task: TCommand;
  Event: TLazBleBackendEvent;
  ResultData: TLazBleRequestResult;
begin
  Task := FCurrent;
  FCurrent := nil;
  try
    if FScan = Task then FScan := nil;
    if Task.Role = crCleanup then
    begin
      { Unsubscribe removes the upstream handler even when a lost connection
        rejects the native call. That cleanup is complete, not a shutdown error. }
      if (Kind = lbekOperationFailed) and (Code <> Ord(ecPeripheralNotConnected)) then
      begin
        if (Task.Parent <> nil) and not Task.Parent.Failed then
        begin
          Task.Parent.Failed := True;
          Task.Parent.ErrorCode := Code;
          Task.Parent.ErrorText := Text;
        end;
        if FStopping and not FShutdownFailed then
        begin
          FShutdownFailed := True;
          FShutdownErrorCode := Code;
          FShutdownError := Text;
        end;
      end;
    end
    else
    begin
      if (Kind = lbekOperationSucceeded) and not FStopping then
      begin
        if Task.Request.Kind = lbckConnect then
          if not Task.Peer.DisconnectedReported then ReportPeer(Task.Peer, True);
        if Task.Request.Kind = lbckDisconnect then ReportPeer(Task.Peer, False);
      end;
      if Task.Completion <> nil then
      begin
        ResultData := Default(TLazBleRequestResult);
        case Kind of
          lbekOperationSucceeded: ResultData.Status := lbrsSucceeded;
          lbekOperationCancelled: ResultData.Status := lbrsCancelled;
          else ResultData.Status := lbrsFailed;
        end;
        ResultData.ErrorCode := Code;
        ResultData.ErrorMessage := Text;
        ResultData.Value := Task.ResultEvent.Value;
        ResultData.Services := Task.ResultEvent.Services;
        ResultData.ScanResults := Task.ScanDevices;
        ResultData.SubscriptionId := Task.ResultEvent.SubscriptionId;
        ResultData.Available := Task.ResultEvent.Available;
        ResultData.BackendName := GetBackendName;
        ResultData.BackendVersion := Task.ResultEvent.BackendVersion;
        ResultData.AdapterId := Task.AdapterId;
        Task.Completion.CompleteRequest(ResultData);
      end
      else
      begin
        if Task.HasResult and (Kind = lbekOperationSucceeded) then Deliver(Task.ResultEvent);
        Event := EventFor(Task, Kind);
        Event.ErrorCode := Code;
        Event.ErrorMessage := Text;
        Deliver(Event);
      end;
    end;
    if (Task.Subscription <> nil) and
      ((Task.Request.Kind = lbckUnsubscribe) or
        ((Task.Request.Kind = lbckSubscribe) and (Kind <> lbekOperationSucceeded))) then
      FSubscriptions.Remove(Task.Subscription);
  finally
    Task.Free;
    { Advancing in a later turn also keeps shutdown after the last OnDone. }
    Schedule;
  end;
end;

procedure TLazBleSimpleBleBackend.StopCurrentScan;
begin
  if FScan = nil then Exit;
  FScan.StopRequested := True;
  FScanTimer.Cancel;
  if FScanning and (FMetadata = nil) then StartMetadata(True);
end;

procedure TLazBleSimpleBleBackend.ScanElapsed;
begin
  StopCurrentScan;
end;

procedure TLazBleSimpleBleBackend.ScanStart(Sender: TBleAdapter);
begin
  if FStopping or (FScan = nil) or (FScan.Adapter <> Sender) or FScan.ScanStarted then Exit;
  FScan.ScanStarted := True;
  Deliver(EventFor(FScan, lbekScanStarted));
end;

procedure TLazBleSimpleBleBackend.ScanStop(Sender: TBleAdapter);
begin
  if FStopping or not FScanning or (FScan = nil) or (FScan.Adapter <> Sender) then Exit;
  if not Sender.ScanIsActive then StopCurrentScan;
end;

procedure TLazBleSimpleBleBackend.ScanFound(Sender: TBleAdapter; Peripheral: TBlePeripheral);
var
  Event: TLazBleBackendEvent;
begin
  if FStopping or (FScan = nil) or (FScan.Adapter <> Sender) then Exit;
  ScanStart(Sender);
  if FStopping then Exit;
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
  Peer.NeedsDisconnect := IsConnected;
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

procedure TLazBleSimpleBleBackend.TPeerContext.Connected(Sender: TBlePeripheral);
begin
  if not Owner.FStopping then Owner.ReportPeer(Self, True);
end;

procedure TLazBleSimpleBleBackend.TPeerContext.Disconnected(Sender: TBlePeripheral);
begin
  { A queued disconnect from the previous owner/session can reach a newly
    attached handler. A connection must first have been reported by this owner. }
  if not Owner.FStopping and ConnectedReported then Owner.ReportPeer(Self, False);
end;

procedure TLazBleSimpleBleBackend.TSubscriptionContext.ValueReceived(Sender: TBlePeripheral;
  const Service, Characteristic: UnicodeString; const Data: TBytes);
var
  Event: TLazBleBackendEvent;
begin
  if Owner.FStopping or not Active then Exit;
  Event := Default(TLazBleBackendEvent);
  Event.Kind := lbekNotification;
  Event.SubscriptionId := Id;
  Event.Generation := Generation;
  Event.DeviceId := Peer.DeviceId;
  Event.ServiceUuid := ServiceUuid;
  Event.CharacteristicUuid := CharacteristicUuid;
  Event.Value := Data;
  Owner.Deliver(Event);
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

end.
