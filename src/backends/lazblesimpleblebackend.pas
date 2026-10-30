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
      Adapter: TBleAdapter;
      AdapterId: string;
      NativePeer: TBlePeripheral;
      Peer: TPeerContext;
      Subscription: TSubscriptionContext;
      ResultEvent: TLazBleBackendEvent;
      ScanDevices: TBleDeviceInfos;
      Cancelled, HasResult, ScanStarted, ScanStopped, TriedScan: Boolean;
    end;
    TStep = (stPrepare, stResolve, stServices, stScanStart, stScanStop,
      stCleanupScan, stCleanupPeer);
    { Only public synchronous metadata and scan calls run here. GATT commands
      use upstream Async methods and never wait in a LazBle worker. }
    TStepWorker = class(TThread)
    private
      FOwner: TLazBleSimpleBleBackend;
      FTask: TCommand;
      FStep: TStep;
      FFailed, FConnected: Boolean;
      FCode: Integer;
      FText: string;
      procedure Complete;
    protected
      procedure Execute; override;
    public
      constructor Create(AOwner: TLazBleSimpleBleBackend; AStep: TStep);
    end;
  private
    FPending: TList;
    FPeers, FSubscriptions: TObjectList;
    FStepWorker: TStepWorker;
    FCurrent, FScan: TCommand;
    FAdapter: TBleAdapter;
    FSink: ILazBleBackendEventSink;
    FScanTimer: ILazBleReconnectTimer;
    FNextId: TBleOperationId;
    FNextSubscription: TBleSubscriptionId;
    FStopping, FDestroying, FQueued, FScanning, FStopRequested: Boolean;
    FShutdownId: TBleOperationId;
    FShutdownDone, FShutdownFailed, FCleanupWaiting: Boolean;
    FShutdownErrorCode: Integer;
    FShutdownError: string;
    FCleanupStage, FCleanupIndex, FRetireIndex: Integer;
    function Hold: ILazBleBackend;
    function NewId: TBleOperationId;
    function FindPeer(Native: TBlePeripheral): TPeerContext;
    function FindSubscription(Id: TBleSubscriptionId): TSubscriptionContext;
    procedure Deliver(const Event: TLazBleBackendEvent);
    function EventFor(Task: TCommand; Kind: TLazBleBackendEventKind): TLazBleBackendEvent;
    procedure Schedule;
    procedure Pump;
    procedure StartStep(Step: TStep);
    procedure RunStep(Worker: TStepWorker);
    procedure StepCompleted(Worker: TStepWorker);
    procedure PreparePeer;
    procedure InvokeCurrent;
    procedure RetireNext;
    procedure Retired(Sender: TObject; Error: Exception);
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
    procedure Connected(Sender: TBlePeripheral);
    procedure Disconnected(Sender: TBlePeripheral);
    procedure ValueReceived(Sender: TBlePeripheral;
      const Service, Characteristic: UnicodeString; const Data: TBytes);
    procedure ReportPeer(Peer: TPeerContext; IsConnected: Boolean);
    procedure DetachCallbacks;
    procedure Cleanup;
    procedure CleanupDone(Sender: TObject; Error: Exception);
    procedure RememberCleanup(Code: Integer; const Text: string);
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

function ErrorCode(Error: Exception): Integer;
begin
  if Error is EBleError then Result := Ord(EBleError(Error).Code)
  else if Error is EBackendError then Result := EBackendError(Error).Code
  else Result := LazBleErrorBackendUnavailable;
end;

constructor TLazBleSimpleBleBackend.TStepWorker.Create(
  AOwner: TLazBleSimpleBleBackend; AStep: TStep);
begin
  inherited Create(True);
  FOwner := AOwner;
  FTask := AOwner.FCurrent;
  FStep := AStep;
  Start;
end;

procedure TLazBleSimpleBleBackend.TStepWorker.Execute;
begin
  try
    FOwner.RunStep(Self);
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

procedure TLazBleSimpleBleBackend.TStepWorker.Complete;
var
  KeepAlive: ILazBleBackend;
begin
  KeepAlive := FOwner.Hold;
  WaitFor;
  FOwner.FStepWorker := nil;
  try
    FOwner.StepCompleted(Self);
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
  { Normal teardown awaits BeginShutdown. Releasing an idle owner also closes
    its native connections; an outstanding native call can delay this fallback. }
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

function TLazBleSimpleBleBackend.FindPeer(Native: TBlePeripheral): TPeerContext;
var
  I: Integer;
begin
  for I := 0 to FPeers.Count - 1 do
    if TPeerContext(FPeers[I]).Native = Native then Exit(TPeerContext(FPeers[I]));
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
begin
  LazBleRequireMainThread;
  if FStopping then Exit(InvalidBleOperationId);
  Task := TCommand.Create;
  Task.Id := NewId;
  Task.Request := ACommand;
  Task.Request.Value := Copy(ACommand.Value);
  FPending.Add(Task);
  Result := Task.Id;
  if ACommand.Kind = lbckStopScan then StopCurrentScan;
  Schedule;
end;

procedure TLazBleSimpleBleBackend.Cancel(const AOperationId: TBleOperationId);
var
  I: Integer;
  Task: TCommand;
begin
  LazBleRequireMainThread;
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
    if FCurrent <> nil then FCurrent.Cancelled := True;
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
  if (FCurrent <> nil) or (FStepWorker <> nil) or FCleanupWaiting then Exit;
  if FPending.Count > 0 then
  begin
    FCurrent := TCommand(FPending[0]);
    FPending.Delete(0);
    if FStopping or FCurrent.Cancelled then
      FinishCurrent(lbekOperationCancelled)
    else if (ActiveBackend <> nil) and (ActiveBackend <> Self) then
      FinishCurrent(lbekOperationFailed, LazBleErrorAdapterAlreadyActive,
        'Another LazBle SimpleDelphiBLE backend is active')
    else
    begin
      ActiveBackend := Self;
      StartStep(stPrepare);
    end;
  end
  else if FStopping then Cleanup;
end;

procedure TLazBleSimpleBleBackend.StartStep(Step: TStep);
begin
  FStepWorker := TStepWorker.Create(Self, Step);
end;

procedure TLazBleSimpleBleBackend.RunStep(Worker: TStepWorker);
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
  case Worker.FStep of
    stPrepare:
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
        if not Task.Adapter.IsPowered then
          raise EBackendError.Create(LazBleErrorBluetoothDisabled, 'Bluetooth adapter is powered off');
      end;
    stResolve:
      begin
        Task.NativePeer := Lookup(Task.Adapter.ScanGetResults);
        if Task.NativePeer = nil then
          Task.NativePeer := Lookup(Task.Adapter.GetConnectedPeripherals);
        if Task.NativePeer = nil then
          Task.NativePeer := Lookup(Task.Adapter.GetPairedPeripherals);
      end;
    stServices: Task.ResultEvent.Services := Task.NativePeer.Services;
    stScanStart: Task.Adapter.ScanStart;
    stScanStop:
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
    stCleanupScan: if FAdapter.ScanIsActive then FAdapter.ScanStop;
    stCleanupPeer:
      Worker.FConnected := TPeerContext(FPeers[FCleanupIndex - 1]).Native.IsConnected;
  end;
end;

procedure TLazBleSimpleBleBackend.StepCompleted(Worker: TStepWorker);
var
  Device: TBleDeviceInfo;
  Event: TLazBleBackendEvent;
  Peer: TPeerContext;
begin
  if Worker.FStep in [stCleanupScan, stCleanupPeer] then
  begin
    if Worker.FFailed then RememberCleanup(Worker.FCode, Worker.FText)
    else if (Worker.FStep = stCleanupPeer) and Worker.FConnected then
    begin
      Peer := TPeerContext(FPeers[FCleanupIndex - 1]);
      FCleanupWaiting := True;
      try
        Peer.Native.DisconnectAsync(@CleanupDone);
      except
        on E: Exception do CleanupDone(nil, E);
      end;
      Exit;
    end;
    Cleanup;
    Exit;
  end;
  if Worker.FFailed then
  begin
    FScanTimer.Cancel;
    FScan := nil;
    FScanning := False;
    FinishCurrent(lbekOperationFailed, Worker.FCode, Worker.FText);
    Exit;
  end;
  try
    case Worker.FStep of
      stPrepare:
        begin
          if (FAdapter <> nil) and (FAdapter <> FCurrent.Adapter) then
            raise EBackendError.Create(LazBleErrorAdapterAlreadyActive,
              'A backend uses one adapter until shutdown');
          FAdapter := FCurrent.Adapter;
          if not FStopping then
          begin
            FAdapter.OnScanStart := @ScanStart;
            FAdapter.OnScanStop := @ScanStop;
            FAdapter.OnScanFound := @ScanFound;
            FAdapter.OnScanUpdated := @ScanFound;
          end;
          if FStopping or FCurrent.Cancelled then FinishCurrent(lbekOperationCancelled)
          else case FCurrent.Request.Kind of
            lbckCheckAvailability:
              begin
                FCurrent.ResultEvent := EventFor(FCurrent, lbekAvailabilityResult);
                FCurrent.ResultEvent.Available := True;
                FCurrent.ResultEvent.BackendVersion := UTF8Encode(TSimpleDelphiBLE.Version);
                FCurrent.HasResult := True;
                FinishCurrent(lbekOperationSucceeded);
              end;
            lbckStartScan:
              begin
                FScan := FCurrent;
                FStopRequested := False;
                StartStep(stScanStart);
              end;
            lbckStopScan: FinishCurrent(lbekOperationSucceeded);
          else StartStep(stResolve);
          end;
        end;
      stResolve:
        if FStopping or FCurrent.Cancelled then FinishCurrent(lbekOperationCancelled)
        else if FCurrent.NativePeer <> nil then
        begin
          PreparePeer;
          if FCurrent.Request.Kind in [lbckConnect, lbckDisconnect] then
          begin
            FRetireIndex := 0;
            RetireNext;
          end
          else InvokeCurrent;
        end
        else if (FCurrent.Request.Kind = lbckConnect) and not FCurrent.TriedScan then
        begin
          FCurrent.TriedScan := True;
          FScan := FCurrent;
          FStopRequested := False;
          StartStep(stScanStart);
        end
        else raise EBackendError.Create(LazBleErrorDeviceNotFound, 'Bluetooth peripheral not found');
      stServices:
        begin
          FCurrent.ResultEvent.Kind := lbekServicesDiscovered;
          FCurrent.HasResult := True;
          FinishCurrent(lbekOperationSucceeded);
        end;
      stScanStart:
        begin
          FScanning := True;
          ScanStart(FCurrent.Adapter);
          if FStopping or FCurrent.Cancelled or FStopRequested then StopCurrentScan
          else if FCurrent.Request.Kind = lbckConnect then FScanTimer.Start(5000, @ScanElapsed)
          else if FCurrent.Request.TimeoutMs > 0 then
            FScanTimer.Start(FCurrent.Request.TimeoutMs, @ScanElapsed);
        end;
      stScanStop:
        begin
          FScanning := False;
          FStopRequested := False;
          FScanTimer.Cancel;
          if (FCurrent.Request.Kind = lbckStartScan) and not FStopping then
          begin
            for Device in FCurrent.ScanDevices do
            begin
              if FStopping then Break;
              ScanStart(FCurrent.Adapter);
              if FStopping then Break;
              Event := EventFor(FCurrent, lbekScanResult);
              Event.DeviceId := Device.DeviceId;
              Event.DeviceName := Device.DeviceName;
              Event.Rssi := Device.Rssi;
              Deliver(Event);
            end;
            if not FStopping and FCurrent.ScanStarted and not FCurrent.ScanStopped then
            begin
              FCurrent.ScanStopped := True;
              Deliver(EventFor(FCurrent, lbekScanStopped));
            end;
          end;
          FScan := nil;
          if FStopping or FCurrent.Cancelled then FinishCurrent(lbekOperationCancelled)
          else if FCurrent.Request.Kind = lbckConnect then StartStep(stResolve)
          else FinishCurrent(lbekOperationSucceeded);
        end;
    end;
  except
    on E: Exception do FailCurrent(E);
  end;
end;

procedure TLazBleSimpleBleBackend.PreparePeer;
var
  I: Integer;
  Sub: TSubscriptionContext;
begin
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
  if FCurrent.Request.Kind = lbckDisconnect then FCurrent.Peer.DisconnectId := FCurrent.Id;
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

procedure TLazBleSimpleBleBackend.RetireNext;
var
  Sub: TSubscriptionContext;
begin
  while FRetireIndex < FSubscriptions.Count do
  begin
    Sub := TSubscriptionContext(FSubscriptions[FRetireIndex]);
    Inc(FRetireIndex);
    if (Sub.Peer <> FCurrent.Peer) or not Sub.Registered then Continue;
    Sub.Active := False;
    Sub.Registered := False;
    try
      Sub.Peer.Native.UnsubscribeAsync(UTF8Decode(Sub.ServiceUuid),
        UTF8Decode(Sub.CharacteristicUuid), @Retired);
    except
      on E: Exception do Retired(nil, E);
    end;
    Exit;
  end;
  InvokeCurrent;
end;

procedure TLazBleSimpleBleBackend.Retired(Sender: TObject; Error: Exception);
var
  KeepAlive: ILazBleBackend;
begin
  KeepAlive := Hold;
  if (Error <> nil) and not (Error is EBleNotConnected) then FailCurrent(Error)
  else RetireNext;
end;

procedure TLazBleSimpleBleBackend.InvokeCurrent;
var
  Service, Characteristic: UnicodeString;
begin
  if FStopping or FCurrent.Cancelled then
  begin
    FinishCurrent(lbekOperationCancelled);
    Exit;
  end;
  FCurrent.ResultEvent := EventFor(FCurrent, lbekOperationSucceeded);
  Service := UTF8Decode(LowerCase(FCurrent.Request.ServiceUuid));
  Characteristic := UTF8Decode(LowerCase(FCurrent.Request.CharacteristicUuid));
  try
    case FCurrent.Request.Kind of
      lbckConnect: FCurrent.NativePeer.ConnectAsync(@CommandDone);
      lbckDisconnect: FCurrent.NativePeer.DisconnectAsync(@CommandDone);
      lbckDiscoverServices: StartStep(stServices);
      lbckRead: FCurrent.NativePeer.ReadAsync(Service, Characteristic, @ReadDone);
      lbckWrite:
        if FCurrent.Request.WriteMode = lbwmCommand then
          FCurrent.NativePeer.WriteCommandAsync(Service, Characteristic, FCurrent.Request.Value, @CommandDone)
        else FCurrent.NativePeer.WriteRequestAsync(Service, Characteristic, FCurrent.Request.Value, @CommandDone);
      lbckSubscribe: FCurrent.NativePeer.NotifyAsync(Service, Characteristic, @ValueReceived, @CommandDone);
      lbckUnsubscribe: FCurrent.NativePeer.UnsubscribeAsync(
        UTF8Decode(FCurrent.Subscription.ServiceUuid),
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
  FCurrent.ResultEvent.Value := Copy(Data);
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
    lbckRead: FCurrent.ResultEvent.Kind := lbekReadResult;
    lbckWrite: FCurrent.ResultEvent.Kind := lbekWriteCompleted;
    lbckSubscribe:
      begin
        FCurrent.Subscription.Registered := True;
        FCurrent.Subscription.Active := not FStopping;
        FCurrent.ResultEvent.Kind := lbekSubscribed;
        FCurrent.ResultEvent.SubscriptionId := FCurrent.Subscription.Id;
      end;
    lbckUnsubscribe: FCurrent.ResultEvent.Kind := lbekUnsubscribed;
  end;
  FCurrent.HasResult := FCurrent.Request.Kind in [lbckRead, lbckWrite, lbckSubscribe, lbckUnsubscribe];
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
begin
  Task := FCurrent;
  FCurrent := nil;
  try
    if FScan = Task then FScan := nil;
    if (Kind = lbekOperationSucceeded) and not FStopping then
    begin
      if Task.Request.Kind = lbckConnect then
        if not Task.Peer.DisconnectedReported then ReportPeer(Task.Peer, True);
      if Task.Request.Kind = lbckDisconnect then ReportPeer(Task.Peer, False);
    end;
    if Task.HasResult and (Kind = lbekOperationSucceeded) then Deliver(Task.ResultEvent);
    if (Task.Subscription <> nil) and
      ((Task.Request.Kind = lbckUnsubscribe) or
        ((Task.Request.Kind = lbckSubscribe) and (Kind <> lbekOperationSucceeded))) then
      FSubscriptions.Remove(Task.Subscription);
    Event := EventFor(Task, Kind);
    Event.ErrorCode := Code;
    Event.ErrorMessage := Text;
    Deliver(Event);
  finally
    Task.Free;
    Schedule;
  end;
end;

procedure TLazBleSimpleBleBackend.StopCurrentScan;
begin
  if FScan = nil then Exit;
  FStopRequested := True;
  FScanTimer.Cancel;
  if FScanning and (FStepWorker = nil) then StartStep(stScanStop);
end;

procedure TLazBleSimpleBleBackend.ScanElapsed;
begin
  StopCurrentScan;
end;

procedure TLazBleSimpleBleBackend.ScanStart(Sender: TBleAdapter);
begin
  if FStopping or (FScan = nil) or (FScan.Adapter <> Sender) then Exit;
  if (FScan.Request.Kind <> lbckStartScan) or FScan.ScanStarted then Exit;
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
  if FScan.Request.Kind = lbckConnect then
  begin
    if SameText(UTF8Encode(Peripheral.Address), FScan.Request.DeviceId) then StopCurrentScan;
    Exit;
  end;
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
  if not FStopping then ReportPeer(FindPeer(Sender), True);
end;

procedure TLazBleSimpleBleBackend.Disconnected(Sender: TBlePeripheral);
var
  Peer: TPeerContext;
begin
  if FStopping then Exit;
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
  if FStopping then Exit;
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
      Event.Value := Data;
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

procedure TLazBleSimpleBleBackend.RememberCleanup(Code: Integer; const Text: string);
begin
  if FShutdownFailed then Exit;
  FShutdownFailed := True;
  FShutdownErrorCode := Code;
  FShutdownError := Text;
end;

procedure TLazBleSimpleBleBackend.CleanupDone(Sender: TObject; Error: Exception);
var
  KeepAlive: ILazBleBackend;
begin
  KeepAlive := Hold;
  if Error <> nil then RememberCleanup(ErrorCode(Error), Error.Message);
  FCleanupWaiting := False;
  Cleanup;
end;

procedure TLazBleSimpleBleBackend.Cleanup;
var
  Sub: TSubscriptionContext;
  Event: TLazBleBackendEvent;
begin
  case FCleanupStage of
    0:
      begin
        FCleanupStage := 1;
        if FAdapter <> nil then
        begin
          StartStep(stCleanupScan);
          Exit;
        end;
      end;
    3:
      begin
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
        Exit;
      end;
  end;
  if FCleanupStage = 1 then
  begin
    while FCleanupIndex < FSubscriptions.Count do
    begin
      Sub := TSubscriptionContext(FSubscriptions[FCleanupIndex]);
      Inc(FCleanupIndex);
      if not Sub.Registered then Continue;
      Sub.Registered := False;
      FCleanupWaiting := True;
      try
        Sub.Peer.Native.UnsubscribeAsync(UTF8Decode(Sub.ServiceUuid),
          UTF8Decode(Sub.CharacteristicUuid), @CleanupDone);
      except
        on E: Exception do CleanupDone(nil, E);
      end;
      Exit;
    end;
    FCleanupIndex := 0;
    FCleanupStage := 2;
  end;
  if FCleanupStage = 2 then
  begin
    if FCleanupIndex < FPeers.Count then
    begin
      Inc(FCleanupIndex);
      StartStep(stCleanupPeer);
      Exit;
    end;
    { Publish shutdown in a later turn, after the last upstream OnDone returns. }
    FCleanupStage := 3;
    Schedule;
  end;
end;

end.
