unit LazBleComponent;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  LazBleTypes,
  LazBleBackend,
  LazBleFacade,
  LazBleClient,
  LazBleOperation,
  LazBleGattProfile,
  LazBleLclScan;

const
  DefaultLazBleScanTimeoutMs = 10000;
  DefaultLazBleReconnectInitialDelayMs = 1000;
  DefaultLazBleReconnectMaximumDelayMs = 30000;
  DefaultLazBleReconnectMaximumAttempts = 5;

type
  TLazBleLclClient = class;

  ELazBleLclDuplicateClient = class(Exception);

  TLazBleLclErrorEvent = procedure(Sender: TObject; const AErrorCode: Integer;
    const AErrorMessage: string) of object;
  TLazBleLclClientChangedEvent = procedure(Sender: TObject) of object;

  { Designer-editable reconnect delays and attempt limit for an LCL client. }
  TLazBleReconnectSettings = class(TPersistent)
  private
    FInitialDelayMs: Cardinal;
    FMaximumDelayMs: Cardinal;
    FMaximumAttempts: Cardinal;
    FOnChange: TNotifyEvent;
    procedure SetInitialDelayMs(const AValue: Cardinal);
    procedure SetMaximumDelayMs(const AValue: Cardinal);
    procedure SetMaximumAttempts(const AValue: Cardinal);
    procedure Changed;
  public
    constructor Create;
    procedure Assign(Source: TPersistent); override;
    function ToOptions: TLazBleReconnectOptions;
  published
    property InitialDelayMs: Cardinal read FInitialDelayMs
      write SetInitialDelayMs default DefaultLazBleReconnectInitialDelayMs;
    property MaximumDelayMs: Cardinal read FMaximumDelayMs
      write SetMaximumDelayMs default DefaultLazBleReconnectMaximumDelayMs;
    property MaximumAttempts: Cardinal read FMaximumAttempts
      write SetMaximumAttempts default DefaultLazBleReconnectMaximumAttempts;
  end;

  { Main-thread owner of one facade. Await ShutdownAsync before destruction.
    Reading properties does not start BLE operations. }
  TLazBleComponent = class(TComponent)
  private
    FBle: TLazBle;
    FScan: TLazBleLclScan;
    FClients: TList;
    FAvailabilityOperation: IBleAvailabilityOperation;
    FAvailability: TBleAvailability;
    FShutdownOperation: IBleOperation;
    FShutdownStarted: Boolean;
    FAdapterId: string;
    FScanTimeoutMs: Cardinal;
    FLastErrorCode: Integer;
    FLastErrorMessage: string;
    FOnScanStateChanged: TLazBleLclScanStateChangedEvent;
    FOnScanResult: TLazBleScanResultEvent;
    FOnScanCompleted: TLazBleLclScanCompletedEvent;
    FOnAvailabilityChanged: TBleAvailabilityEvent;
    FOnError: TLazBleLclErrorEvent;
    procedure Initialize(const ABle: TLazBle);
    procedure EnsureOperational;
    function GetScanState: TLazBleLclScanState;
    function GetScanResults: TBleDeviceInfos;
    function GetLastErrorCode: Integer;
    function GetLastErrorMessage: string;
    function GetBackendInfo: TLazBleBackendInfo;
    function GetDiagnosticInfo: TLazBleDiagnosticInfo;
    function GetClientCount: Integer;
    function GetClient(const AIndex: Integer): TLazBleLclClient;
    procedure ValidateClientDeviceId(const AClient: TLazBleLclClient;
      const ADeviceId: string);
    procedure NotifyClientsChanged;
    procedure RegisterClient(const AClient: TLazBleLclClient);
    procedure UnregisterClient(const AClient: TLazBleLclClient);
    procedure ScanStateChanged(Sender: TObject;
      const AState: TLazBleLclScanState);
    procedure ScanResult(Sender: TObject; const ADeviceId,
      ADeviceName: string; const ARssi: SmallInt);
    procedure ScanCompleted(Sender: TObject;
      const AState: TLazBleLclScanState);
    procedure AvailabilityCompleted(Sender: TObject);
    procedure SetAvailability(const AAvailability: TBleAvailability);
  protected
    function CreateFacade: TLazBle; virtual;
  public
    constructor Create(AOwner: TComponent); override; overload;
    constructor Create(AOwner: TComponent;
      const ABackend: ILazBleBackend); reintroduce; overload;
    destructor Destroy; override;
    { Start a scan with AdapterId and ScanTimeoutMs. Events run on the main
      thread; ScanResults retains devices seen during the current scan. }
    procedure StartScan;
    procedure CancelScan;
    procedure ClearScanResults;
    { Starts or repeats the asynchronous check for AdapterId. Results arrive
      through OnAvailabilityChanged and, on failure, OnError. }
    procedure RefreshAvailability;
    { Stop scan, availability work, and owned clients. }
    procedure Shutdown;
    { Await this operation before freeing the component/form. A failed result
      still marks completed cleanup; preserve its diagnostic. Never wait in a callback. }
    function ShutdownAsync: IBleOperation;
    { Create a component-owned client for a unique device ID. }
    function CreateClient(const ADeviceId: string): TLazBleLclClient;
    function FindClient(const ADeviceId: string): TLazBleLclClient;
    procedure RemoveClient(const AClient: TLazBleLclClient);
    property ScanState: TLazBleLclScanState read GetScanState;
    property Availability: TBleAvailability read FAvailability;
    property ScanResults: TBleDeviceInfos read GetScanResults;
    property ScanController: TLazBleLclScan read FScan;
    property LastErrorCode: Integer read GetLastErrorCode;
    property LastErrorMessage: string read GetLastErrorMessage;
    { Backend metadata from the latest availability result. Fields may be
      empty before a check, during a repeat check, or after load failure. }
    property BackendInfo: TLazBleBackendInfo read GetBackendInfo;
    { Main-thread snapshot; available without RefreshAvailability. Native
      dependencies are required at process startup. Read on the owning thread;
      read this property again after availability changes for current values. }
    property DiagnosticInfo: TLazBleDiagnosticInfo read GetDiagnosticInfo;
    property ClientCount: Integer read GetClientCount;
    property Clients[const AIndex: Integer]: TLazBleLclClient
      read GetClient;
    property Facade: TLazBle read FBle;
  published
    { Empty selects the backend's default adapter. }
    property AdapterId: string read FAdapterId write FAdapterId;
    property ScanTimeoutMs: Cardinal read FScanTimeoutMs write FScanTimeoutMs
      default DefaultLazBleScanTimeoutMs;
    property OnScanStateChanged: TLazBleLclScanStateChangedEvent
      read FOnScanStateChanged write FOnScanStateChanged;
    property OnScanResult: TLazBleScanResultEvent
      read FOnScanResult write FOnScanResult;
    property OnScanCompleted: TLazBleLclScanCompletedEvent
      read FOnScanCompleted write FOnScanCompleted;
    property OnAvailabilityChanged: TBleAvailabilityEvent
      read FOnAvailabilityChanged write FOnAvailabilityChanged;
    property OnError: TLazBleLclErrorEvent read FOnError write FOnError;
  end;

  { LCL wrapper for a device client. Assign LazBle and DeviceId or call
    SelectDevice, then configure profiles through OnConfigureClient. }
  TLazBleLclClient = class(TComponent)
  private
    FLazBle: TLazBleComponent;
    FDeviceId: string;
    FDeviceName: string;
    FCoreClient: TBleClient;
    FGeneration: QWord;
    FDetaching: Boolean;
    FConnectOperation: IBleOperation;
    FDisconnectOperation: IBleOperation;
    FLastErrorCode: Integer;
    FLastErrorMessage: string;
    FAutoReconnect: Boolean;
    FReconnectOptions: TLazBleReconnectSettings;
    FOnConfigureClient: TNotifyEvent;
    FOnUnconfigureClient: TNotifyEvent;
    FOnDeviceChanged: TNotifyEvent;
    FOnStateChanged: TLazBleClientStateChangedEvent;
    FOnConnected: TNotifyEvent;
    FOnDisconnected: TNotifyEvent;
    FOnError: TLazBleLclErrorEvent;
    FChangedHandlers: array of TLazBleLclClientChangedEvent;
    procedure SetLazBle(const AValue: TLazBleComponent);
    procedure SetDeviceId(const AValue: string);
    procedure SetDeviceIdentity(const ADeviceId, ADeviceName: string);
    procedure SetAutoReconnect(const AValue: Boolean);
    procedure SetReconnectOptions(const AValue: TLazBleReconnectSettings);
    function GetState: TLazBleClientState;
    function GetReconnectAttempt: Cardinal;
    function GetReconnectDelayMs: Cardinal;
    procedure ReconnectSettingsChanged(Sender: TObject);
    procedure ApplyReconnectSettings;
    procedure EnsureCoreClient;
    procedure RemoveReplaceableCoreClient;
    procedure DetachCoreClient;
    procedure CoreStateChanged(Sender: TObject;
      const AState: TLazBleClientState);
    procedure ConnectCompleted(Sender: TObject);
    procedure DisconnectCompleted(Sender: TObject);
    procedure CompleteOperation(Sender: TObject; const AConnecting: Boolean);
    procedure NotifyChanged;
    procedure RootComponentShuttingDown(const ARoot: TLazBleComponent);
    procedure RootComponentDestroying(const ARoot: TLazBleComponent);
  protected
    procedure Notification(AComponent: TComponent;
      Operation: TOperation); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { Set both DeviceId and the displayed DeviceName from a scan result. }
    procedure SelectDevice(const ADevice: TBleDeviceInfo);
    { Transfer profile ownership to the underlying client before connection. }
    procedure AddProfile(const AProfile: TBleGattProfile;
      const ARequired: Boolean = True);
    { Start asynchronous connection; watch OnConnected or OnError. }
    procedure Connect;
    { Start asynchronous disconnection; watch OnDisconnected. }
    procedure Disconnect;
    procedure AddChangedHandler(const AHandler: TLazBleLclClientChangedEvent);
    procedure RemoveChangedHandler(
      const AHandler: TLazBleLclClientChangedEvent);
    property DeviceName: string read FDeviceName;
    property State: TLazBleClientState read GetState;
    property LastErrorCode: Integer read FLastErrorCode;
    property LastErrorMessage: string read FLastErrorMessage;
    property ReconnectAttempt: Cardinal read GetReconnectAttempt;
    property ReconnectDelayMs: Cardinal read GetReconnectDelayMs;
    { Created on demand; may be nil until the first client operation. }
    property CoreClient: TBleClient read FCoreClient;
  published
    property LazBle: TLazBleComponent read FLazBle write SetLazBle;
    property DeviceId: string read FDeviceId write SetDeviceId;
    property AutoReconnect: Boolean read FAutoReconnect
      write SetAutoReconnect default False;
    property ReconnectOptions: TLazBleReconnectSettings
      read FReconnectOptions write SetReconnectOptions;
    { Add profiles here when the underlying client is created. }
    property OnConfigureClient: TNotifyEvent read FOnConfigureClient
      write FOnConfigureClient;
    { Release borrowed profile/client references here, before the core client
      is detached or destroyed. Do not start client operations in this callback. }
    property OnUnconfigureClient: TNotifyEvent read FOnUnconfigureClient
      write FOnUnconfigureClient;
    property OnDeviceChanged: TNotifyEvent read FOnDeviceChanged
      write FOnDeviceChanged;
    property OnStateChanged: TLazBleClientStateChangedEvent
      read FOnStateChanged write FOnStateChanged;
    property OnConnected: TNotifyEvent read FOnConnected write FOnConnected;
    property OnDisconnected: TNotifyEvent read FOnDisconnected
      write FOnDisconnected;
    property OnError: TLazBleLclErrorEvent read FOnError write FOnError;
  end;

implementation

constructor TLazBleReconnectSettings.Create;
begin
  inherited Create;
  FInitialDelayMs := DefaultLazBleReconnectInitialDelayMs;
  FMaximumDelayMs := DefaultLazBleReconnectMaximumDelayMs;
  FMaximumAttempts := DefaultLazBleReconnectMaximumAttempts;
end;

procedure TLazBleReconnectSettings.Assign(Source: TPersistent);
var
  Settings: TLazBleReconnectSettings;
begin
  if Source is TLazBleReconnectSettings then
  begin
    Settings := TLazBleReconnectSettings(Source);
    FInitialDelayMs := Settings.InitialDelayMs;
    FMaximumDelayMs := Settings.MaximumDelayMs;
    FMaximumAttempts := Settings.MaximumAttempts;
    Changed;
  end
  else
    inherited Assign(Source);
end;

function TLazBleReconnectSettings.ToOptions: TLazBleReconnectOptions;
begin
  Result := TLazBleReconnectOptions.Create(FInitialDelayMs,
    FMaximumDelayMs, FMaximumAttempts);
end;

procedure TLazBleReconnectSettings.SetInitialDelayMs(
  const AValue: Cardinal);
begin
  if AValue = FInitialDelayMs then
    Exit;
  if (AValue = 0) or (AValue > FMaximumDelayMs) then
    raise EArgumentOutOfRangeException.Create('InitialDelayMs');
  FInitialDelayMs := AValue;
  Changed;
end;

procedure TLazBleReconnectSettings.SetMaximumDelayMs(
  const AValue: Cardinal);
begin
  if AValue = FMaximumDelayMs then
    Exit;
  if AValue < FInitialDelayMs then
    raise EArgumentOutOfRangeException.Create('MaximumDelayMs');
  FMaximumDelayMs := AValue;
  Changed;
end;

procedure TLazBleReconnectSettings.SetMaximumAttempts(
  const AValue: Cardinal);
begin
  if AValue = FMaximumAttempts then
    Exit;
  if AValue = 0 then
    raise EArgumentOutOfRangeException.Create('MaximumAttempts');
  FMaximumAttempts := AValue;
  Changed;
end;

procedure TLazBleReconnectSettings.Changed;
var
  Handler: TNotifyEvent;
begin
  Handler := FOnChange;
  if Assigned(Handler) then
    Handler(Self);
end;

constructor TLazBleComponent.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FScanTimeoutMs := DefaultLazBleScanTimeoutMs;
  Initialize(CreateFacade);
end;

constructor TLazBleComponent.Create(AOwner: TComponent;
  const ABackend: ILazBleBackend);
begin
  inherited Create(AOwner);
  if not Assigned(ABackend) then
    raise EArgumentNilException.Create('ABackend');
  FScanTimeoutMs := DefaultLazBleScanTimeoutMs;
  Initialize(TLazBle.Create(ABackend));
end;

destructor TLazBleComponent.Destroy;
var
  Index: Integer;
  Client: TLazBleLclClient;
  Snapshot: array of TLazBleLclClient;
begin
  Shutdown;
  if Assigned(FClients) then
  begin
    Snapshot := nil;
    SetLength(Snapshot, FClients.Count);
    for Index := 0 to FClients.Count - 1 do
      Snapshot[Index] := TLazBleLclClient(FClients[Index]);
    for Client in Snapshot do
      if FClients.IndexOf(Client) >= 0 then Client.RootComponentDestroying(Self);
  end;
  if Assigned(FClients) then
    FClients.Clear;
  if Assigned(FScan) then
  begin
    FScan.OnStateChanged := nil;
    FScan.OnResult := nil;
    FScan.OnCompleted := nil;
  end;
  FScan.Free;
  FScan := nil;
  FAvailabilityOperation := nil;
  FShutdownOperation := nil;
  FBle.Free;
  FBle := nil;
  FClients.Free;
  FClients := nil;
  inherited Destroy;
end;

function TLazBleComponent.CreateFacade: TLazBle;
begin
  Result := TLazBle.Create;
end;

procedure TLazBleComponent.Initialize(const ABle: TLazBle);
begin
  FClients := TList.Create;
  FBle := ABle;
  FAvailability := lbaUnknown;
  FScan := TLazBleLclScan.Create(FBle);
  FScan.OnStateChanged := @ScanStateChanged;
  FScan.OnResult := @ScanResult;
  FScan.OnCompleted := @ScanCompleted;
end;

procedure TLazBleComponent.EnsureOperational;
begin
  LazBleRequireMainThread;
  if FShutdownStarted then
    raise EInvalidOperation.Create('LazBle component is shut down');
end;

procedure TLazBleComponent.StartScan;
begin
  EnsureOperational;
  FLastErrorCode := 0;
  FLastErrorMessage := '';
  FScan.Start(FAdapterId, FScanTimeoutMs);
end;

procedure TLazBleComponent.CancelScan;
begin
  FScan.Cancel;
end;

procedure TLazBleComponent.ClearScanResults;
begin
  FScan.ClearResults;
end;

procedure TLazBleComponent.RefreshAvailability;
begin
  EnsureOperational;
  if Assigned(FAvailabilityOperation) and
    (FAvailabilityOperation.State = lbopPending) then
    Exit;
  if Assigned(FAvailabilityOperation) then
    FAvailabilityOperation.OnCompleted := nil;
  FAvailabilityOperation := nil;
  FLastErrorCode := 0;
  FLastErrorMessage := '';
  SetAvailability(lbaChecking);
  if FShutdownStarted or Assigned(FAvailabilityOperation) then Exit;
  FAvailabilityOperation := FBle.CheckAvailabilityAsync(FAdapterId);
  FAvailabilityOperation.OnCompleted := @AvailabilityCompleted;
end;

procedure TLazBleComponent.Shutdown;
begin
  ShutdownAsync;
end;

function TLazBleComponent.ShutdownAsync: IBleOperation;
var
  Index: Integer;
  Client: TLazBleLclClient;
  Snapshot: array of TLazBleLclClient;
begin
  LazBleRequireMainThread;
  if FShutdownStarted then
    Exit(FShutdownOperation);
  FShutdownStarted := True;
  if Assigned(FAvailabilityOperation) then
    FAvailabilityOperation.OnCompleted := nil;
  FAvailabilityOperation := nil;
  FAvailability := lbaUnavailable;
  if Assigned(FScan) then
  begin
    FScan.OnStateChanged := nil;
    FScan.OnResult := nil;
    FScan.OnCompleted := nil;
    FScan.Shutdown;
  end;
  if Assigned(FClients) then
  begin
    Snapshot := nil;
    SetLength(Snapshot, FClients.Count);
    for Index := 0 to FClients.Count - 1 do
      Snapshot[Index] := TLazBleLclClient(FClients[Index]);
    for Client in Snapshot do
      if FClients.IndexOf(Client) >= 0 then Client.RootComponentShuttingDown(Self);
  end;
  if Assigned(FBle) then
    FShutdownOperation := FBle.ShutdownAsync;
  Result := FShutdownOperation;
end;

function TLazBleComponent.CreateClient(
  const ADeviceId: string): TLazBleLclClient;
begin
  EnsureOperational;
  if ADeviceId = '' then
    raise EArgumentException.Create('BLE device id must not be empty');
  Result := TLazBleLclClient.Create(Self);
  try
    Result.DeviceId := ADeviceId;
    Result.LazBle := Self;
  except
    Result.Free;
    raise;
  end;
end;

function TLazBleComponent.FindClient(
  const ADeviceId: string): TLazBleLclClient;
var
  Index: Integer;
begin
  Result := nil;
  if ADeviceId = '' then
    Exit;
  for Index := 0 to FClients.Count - 1 do
    if SameText(TLazBleLclClient(FClients[Index]).DeviceId,
      ADeviceId) then
      Exit(TLazBleLclClient(FClients[Index]));
end;

procedure TLazBleComponent.RemoveClient(const AClient: TLazBleLclClient);
var
  OwnedClient: Boolean;
begin
  if not Assigned(AClient) then
    raise EArgumentNilException.Create('AClient');
  if (AClient.LazBle <> Self) or (FClients.IndexOf(AClient) < 0) then
    raise EArgumentException.Create(
      'Client does not belong to this LazBle component');
  OwnedClient := AClient.Owner = Self;
  AClient.LazBle := nil;
  if OwnedClient then
    AClient.Free;
end;

function TLazBleComponent.GetScanState: TLazBleLclScanState;
begin
  Result := FScan.State;
end;

function TLazBleComponent.GetScanResults: TBleDeviceInfos;
begin
  Result := FScan.Results;
end;

function TLazBleComponent.GetLastErrorCode: Integer;
begin
  Result := FLastErrorCode;
end;

function TLazBleComponent.GetLastErrorMessage: string;
begin
  Result := FLastErrorMessage;
end;

function TLazBleComponent.GetBackendInfo: TLazBleBackendInfo;
begin
  if Assigned(FBle) then
    Result := FBle.BackendInfo
  else
    Result := Default(TLazBleBackendInfo);
end;

function TLazBleComponent.GetDiagnosticInfo: TLazBleDiagnosticInfo;
begin
  if Assigned(FBle) then
    Result := FBle.DiagnosticInfo
  else
    Result := Default(TLazBleDiagnosticInfo);
end;

function TLazBleComponent.GetClientCount: Integer;
begin
  Result := FClients.Count;
end;

function TLazBleComponent.GetClient(
  const AIndex: Integer): TLazBleLclClient;
begin
  Result := TLazBleLclClient(FClients[AIndex]);
end;

procedure TLazBleComponent.ValidateClientDeviceId(
  const AClient: TLazBleLclClient; const ADeviceId: string);
var
  ExistingClient: TLazBleLclClient;
begin
  if ADeviceId = '' then
    Exit;
  ExistingClient := FindClient(ADeviceId);
  if Assigned(ExistingClient) and (ExistingClient <> AClient) then
    raise ELazBleLclDuplicateClient.CreateFmt(
      'A LazBle LCL client already uses device "%s"', [ADeviceId]);
end;

procedure TLazBleComponent.RegisterClient(
  const AClient: TLazBleLclClient);
begin
  EnsureOperational;
  if FClients.IndexOf(AClient) >= 0 then
    Exit;
  ValidateClientDeviceId(AClient, AClient.DeviceId);
  FClients.Add(AClient);
end;

procedure TLazBleComponent.UnregisterClient(
  const AClient: TLazBleLclClient);
begin
  FClients.Remove(AClient);
end;

procedure TLazBleComponent.NotifyClientsChanged;
var
  Client: TLazBleLclClient;
  ClientSnapshot: array of TLazBleLclClient;
  Index: Integer;
begin
  ClientSnapshot := nil;
  SetLength(ClientSnapshot, FClients.Count);
  for Index := 0 to FClients.Count - 1 do
    ClientSnapshot[Index] := TLazBleLclClient(FClients[Index]);
  for Client in ClientSnapshot do
    if FClients.IndexOf(Client) >= 0 then
      Client.NotifyChanged;
end;

procedure TLazBleComponent.ScanStateChanged(Sender: TObject;
  const AState: TLazBleLclScanState);
var
  Handler: TLazBleLclScanStateChangedEvent;
begin
  NotifyClientsChanged;
  if FShutdownStarted or (FScan.State <> AState) then Exit;
  Handler := FOnScanStateChanged;
  if Assigned(Handler) then
    Handler(Self, AState);
end;

procedure TLazBleComponent.ScanResult(Sender: TObject;
  const ADeviceId, ADeviceName: string; const ARssi: SmallInt);
var
  Handler: TLazBleScanResultEvent;
begin
  Handler := FOnScanResult;
  if Assigned(Handler) then
    Handler(Self, ADeviceId, ADeviceName, ARssi);
end;

procedure TLazBleComponent.ScanCompleted(Sender: TObject;
  const AState: TLazBleLclScanState);
var
  CompletedHandler: TLazBleLclScanCompletedEvent;
  ErrorHandler: TLazBleLclErrorEvent;
begin
  if AState = lblssFailed then
  begin
    FLastErrorCode := FScan.ErrorCode;
    FLastErrorMessage := FScan.ErrorMessage;
    ErrorHandler := FOnError;
    if Assigned(ErrorHandler) then
      ErrorHandler(Self, FLastErrorCode, FLastErrorMessage);
  end;

  if FShutdownStarted or (FScan.State <> AState) then Exit;
  CompletedHandler := FOnScanCompleted;
  if Assigned(CompletedHandler) then
    CompletedHandler(Self, AState);
end;

procedure TLazBleComponent.AvailabilityCompleted(Sender: TObject);
var
  Operation: IBleAvailabilityOperation;
  ErrorHandler: TLazBleLclErrorEvent;
begin
  LazBleRequireMainThread;
  if FShutdownStarted or not Assigned(FAvailabilityOperation) or
    (FAvailabilityOperation <> (Sender as IBleAvailabilityOperation)) then Exit;
  Operation := FAvailabilityOperation;
  FAvailabilityOperation := nil;
  Operation.OnCompleted := nil;
  if Operation.State = lbopSucceeded then
    SetAvailability(Operation.Availability)
  else if Operation.State = lbopCancelled then
    SetAvailability(lbaUnknown)
  else
  begin
    FLastErrorCode := Operation.ErrorCode;
    FLastErrorMessage := Operation.ErrorMessage;
    SetAvailability(lbaUnavailable);
    if FShutdownStarted or Assigned(FAvailabilityOperation) then Exit;
    ErrorHandler := FOnError;
    if Assigned(ErrorHandler) then
      ErrorHandler(Self, Operation.ErrorCode, Operation.ErrorMessage);
  end;
end;

procedure TLazBleComponent.SetAvailability(
  const AAvailability: TBleAvailability);
var
  Handler: TBleAvailabilityEvent;
begin
  if FAvailability = AAvailability then
    Exit;
  FAvailability := AAvailability;
  NotifyClientsChanged;
  if FShutdownStarted or (FAvailability <> AAvailability) then Exit;
  Handler := FOnAvailabilityChanged;
  if Assigned(Handler) then
    Handler(Self, FAvailability);
end;

constructor TLazBleLclClient.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FReconnectOptions := TLazBleReconnectSettings.Create;
  FReconnectOptions.FOnChange := @ReconnectSettingsChanged;
end;

destructor TLazBleLclClient.Destroy;
var
  OldCoreClient: TBleClient;
begin
  FReconnectOptions.FOnChange := nil;
  OldCoreClient := FCoreClient;
  DetachCoreClient;
  if Assigned(OldCoreClient) and Assigned(FLazBle) and
    (OldCoreClient.State = lbcstDisconnected) then
    FLazBle.Facade.RemoveClient(OldCoreClient);
  if Assigned(FLazBle) then
  begin
    FLazBle.UnregisterClient(Self);
    FLazBle.RemoveFreeNotification(Self);
  end;
  FLazBle := nil;
  FReconnectOptions.Free;
  FReconnectOptions := nil;
  inherited Destroy;
end;

procedure TLazBleLclClient.SetLazBle(const AValue: TLazBleComponent);
begin
  if FLazBle = AValue then
    Exit;
  if Assigned(AValue) then
  begin
    AValue.EnsureOperational;
    AValue.ValidateClientDeviceId(Self, FDeviceId);
  end;
  RemoveReplaceableCoreClient;
  if Assigned(FLazBle) then
  begin
    FLazBle.UnregisterClient(Self);
    FLazBle.RemoveFreeNotification(Self);
  end;
  FLazBle := AValue;
  if Assigned(FLazBle) then
  begin
    FLazBle.RegisterClient(Self);
    FLazBle.FreeNotification(Self);
  end;
  NotifyChanged;
end;

procedure TLazBleLclClient.SetDeviceId(const AValue: string);
begin
  if FDeviceId = AValue then
    Exit;
  SetDeviceIdentity(AValue, '');
end;

procedure TLazBleLclClient.SetDeviceIdentity(const ADeviceId,
  ADeviceName: string);
var
  Handler: TNotifyEvent;
  IdentityChanged: Boolean;
begin
  IdentityChanged := (FDeviceId <> ADeviceId) or
    (FDeviceName <> ADeviceName);
  if Assigned(FLazBle) then
    FLazBle.ValidateClientDeviceId(Self, ADeviceId);
  if FDeviceId <> ADeviceId then
    RemoveReplaceableCoreClient;
  FDeviceId := ADeviceId;
  FDeviceName := ADeviceName;
  NotifyChanged;
  if IdentityChanged then
  begin
    Handler := FOnDeviceChanged;
    if Assigned(Handler) then
      Handler(Self);
  end;
end;

procedure TLazBleLclClient.SetAutoReconnect(const AValue: Boolean);
begin
  if FAutoReconnect = AValue then
    Exit;
  FAutoReconnect := AValue;
  if Assigned(FCoreClient) then
    FCoreClient.AutoReconnect := FAutoReconnect;
end;

procedure TLazBleLclClient.SetReconnectOptions(
  const AValue: TLazBleReconnectSettings);
begin
  if not Assigned(AValue) then
    raise EArgumentNilException.Create('AValue');
  FReconnectOptions.Assign(AValue);
end;

function TLazBleLclClient.GetState: TLazBleClientState;
begin
  if Assigned(FCoreClient) then
    Result := FCoreClient.State
  else
    Result := lbcstDisconnected;
end;

function TLazBleLclClient.GetReconnectAttempt: Cardinal;
begin
  if Assigned(FCoreClient) then
    Result := FCoreClient.ReconnectAttempt
  else
    Result := 0;
end;

function TLazBleLclClient.GetReconnectDelayMs: Cardinal;
begin
  if Assigned(FCoreClient) then
    Result := FCoreClient.ReconnectDelayMs
  else
    Result := 0;
end;

procedure TLazBleLclClient.ReconnectSettingsChanged(Sender: TObject);
begin
  if Assigned(FCoreClient) then
    FCoreClient.ReconnectOptions := FReconnectOptions.ToOptions;
end;

procedure TLazBleLclClient.ApplyReconnectSettings;
begin
  FCoreClient.ReconnectOptions := FReconnectOptions.ToOptions;
  FCoreClient.AutoReconnect := FAutoReconnect;
end;

procedure TLazBleLclClient.EnsureCoreClient;
var
  Handler: TNotifyEvent;
begin
  LazBleRequireMainThread;
  if FDetaching then raise EInvalidOperation.Create(
    'Client operations are not allowed during unconfiguration');
  if Assigned(FCoreClient) then
    Exit;
  if not Assigned(FLazBle) then
    raise EInvalidOperation.Create('LazBle component is not assigned');
  FLazBle.EnsureOperational;
  if FDeviceId = '' then
    raise EInvalidOperation.Create('BLE device is not selected');

  FCoreClient := FLazBle.Facade.CreateClient(FDeviceId);
  FCoreClient.OnStateChanged := @CoreStateChanged;
  try
    ApplyReconnectSettings;
    Handler := FOnConfigureClient;
    if Assigned(Handler) then
      Handler(Self);
  except
    FCoreClient.OnStateChanged := nil;
    FLazBle.Facade.RemoveClient(FCoreClient);
    FCoreClient := nil;
    raise;
  end;
end;

procedure TLazBleLclClient.RemoveReplaceableCoreClient;
var
  OldCoreClient: TBleClient;
begin
  if FDetaching then raise EInvalidOperation.Create(
    'Client cannot be replaced during unconfiguration');
  if not Assigned(FCoreClient) then
    Exit;
  if not (FCoreClient.State in [lbcstDisconnected, lbcstError]) then
    raise EInvalidOperation.Create(
      'BLE device can only be changed while disconnected or in error');
  Inc(FGeneration);
  OldCoreClient := FCoreClient;
  DetachCoreClient;
  if Assigned(FLazBle) then
    FLazBle.Facade.RemoveClient(OldCoreClient);
end;

procedure TLazBleLclClient.DetachCoreClient;
var
  Handler: TNotifyEvent;
begin
  Inc(FGeneration);
  if Assigned(FCoreClient) then
  begin
    FDetaching := True;
    try
      Handler := FOnUnconfigureClient;
      if Assigned(Handler) then Handler(Self);
    finally
      FDetaching := False;
    end;
  end;
  if Assigned(FConnectOperation) then
    FConnectOperation.OnCompleted := nil;
  if Assigned(FDisconnectOperation) then
    FDisconnectOperation.OnCompleted := nil;
  FConnectOperation := nil;
  FDisconnectOperation := nil;
  if Assigned(FCoreClient) then
    FCoreClient.OnStateChanged := nil;
  FCoreClient := nil;
end;

procedure TLazBleLclClient.Notification(AComponent: TComponent;
  Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  if (Operation = opRemove) and (AComponent = FLazBle) then
  begin
    Inc(FGeneration);
    if Assigned(FConnectOperation) then
      FConnectOperation.OnCompleted := nil;
    if Assigned(FDisconnectOperation) then
      FDisconnectOperation.OnCompleted := nil;
    FConnectOperation := nil;
    FDisconnectOperation := nil;
    FCoreClient := nil;
    FLazBle := nil;
    NotifyChanged;
  end;
end;

procedure TLazBleLclClient.SelectDevice(const ADevice: TBleDeviceInfo);
begin
  SetDeviceIdentity(ADevice.DeviceId, ADevice.DeviceName);
end;

procedure TLazBleLclClient.AddProfile(const AProfile: TBleGattProfile;
  const ARequired: Boolean);
begin
  EnsureCoreClient;
  FCoreClient.AddProfile(AProfile, ARequired);
end;

procedure TLazBleLclClient.Connect;
var
  Operation: IBleOperation;
  Generation: QWord;
begin
  if Assigned(FConnectOperation) and
    (FConnectOperation.State = lbopPending) then
    Exit;
  if Assigned(FConnectOperation) then
    FConnectOperation.OnCompleted := nil;
  FConnectOperation := nil;
  if Assigned(FCoreClient) and (FCoreClient.State = lbcstError) then
    RemoveReplaceableCoreClient;
  EnsureCoreClient;
  if not Assigned(FCoreClient) or not Assigned(FLazBle) or
    FLazBle.FShutdownStarted then Exit;
  FLastErrorCode := 0;
  FLastErrorMessage := '';
  Inc(FGeneration);
  Generation := FGeneration;
  Operation := FCoreClient.ConnectAsync;
  if Generation <> FGeneration then Exit;
  FConnectOperation := Operation;
  Operation.OnCompleted := @ConnectCompleted;
end;

procedure TLazBleLclClient.Disconnect;
var
  Operation: IBleOperation;
  Generation: QWord;
begin
  LazBleRequireMainThread;
  if FDetaching then raise EInvalidOperation.Create(
    'Client operations are not allowed during unconfiguration');
  if not Assigned(FCoreClient) then
    Exit;
  if Assigned(FDisconnectOperation) and
    (FDisconnectOperation.State = lbopPending) then
    Exit;
  if Assigned(FDisconnectOperation) then
    FDisconnectOperation.OnCompleted := nil;
  if Assigned(FConnectOperation) then
    FConnectOperation.OnCompleted := nil;
  FDisconnectOperation := nil;
  FConnectOperation := nil;
  FLastErrorCode := 0;
  FLastErrorMessage := '';
  Inc(FGeneration);
  Generation := FGeneration;
  Operation := FCoreClient.DisconnectAsync;
  if Generation <> FGeneration then Exit;
  FDisconnectOperation := Operation;
  Operation.OnCompleted := @DisconnectCompleted;
end;

procedure TLazBleLclClient.CoreStateChanged(Sender: TObject;
  const AState: TLazBleClientState);
var
  StateHandler: TLazBleClientStateChangedEvent;
  Generation: QWord;
begin
  LazBleRequireMainThread;
  if (Sender <> FCoreClient) or not Assigned(FLazBle) or
    FLazBle.FShutdownStarted then Exit;
  Generation := FGeneration;
  StateHandler := FOnStateChanged;
  if Assigned(StateHandler) then StateHandler(Self, AState);
  if (Generation = FGeneration) and (Sender = FCoreClient) and
    (GetState = AState) then NotifyChanged;
end;

procedure TLazBleLclClient.ConnectCompleted(Sender: TObject);
begin
  CompleteOperation(Sender, True);
end;

procedure TLazBleLclClient.DisconnectCompleted(Sender: TObject);
begin
  CompleteOperation(Sender, False);
end;

procedure TLazBleLclClient.CompleteOperation(Sender: TObject;
  const AConnecting: Boolean);
var
  Operation: IBleOperation;
  Handler: TNotifyEvent;
  ErrorHandler: TLazBleLclErrorEvent;
  Generation: QWord;
begin
  LazBleRequireMainThread;
  if not Assigned(FLazBle) or FLazBle.FShutdownStarted then Exit;
  if AConnecting then Operation := FConnectOperation
  else Operation := FDisconnectOperation;
  if not Assigned(Operation) or (Operation <> (Sender as IBleOperation)) then Exit;
  if AConnecting then FConnectOperation := nil else FDisconnectOperation := nil;
  Operation.OnCompleted := nil;
  Generation := FGeneration;
  if Operation.State = lbopSucceeded then
  begin
    if AConnecting then Handler := FOnConnected else Handler := FOnDisconnected;
    if Assigned(Handler) then Handler(Self);
  end
  else if Operation.State = lbopFailed then
  begin
    FLastErrorCode := Operation.ErrorCode;
    FLastErrorMessage := Operation.ErrorMessage;
    ErrorHandler := FOnError;
    if Assigned(ErrorHandler) then
      ErrorHandler(Self, Operation.ErrorCode, Operation.ErrorMessage);
  end;
  if Generation = FGeneration then NotifyChanged;
end;

procedure TLazBleLclClient.AddChangedHandler(
  const AHandler: TLazBleLclClientChangedEvent);
var
  Handler: TLazBleLclClientChangedEvent;
  Index: Integer;
begin
  if not Assigned(AHandler) then
    Exit;
  for Handler in FChangedHandlers do
    if (TMethod(Handler).Code = TMethod(AHandler).Code) and
      (TMethod(Handler).Data = TMethod(AHandler).Data) then
      Exit;
  Index := Length(FChangedHandlers);
  SetLength(FChangedHandlers, Index + 1);
  FChangedHandlers[Index] := AHandler;
end;

procedure TLazBleLclClient.RemoveChangedHandler(
  const AHandler: TLazBleLclClientChangedEvent);
var
  Index: Integer;
begin
  for Index := 0 to High(FChangedHandlers) do
    if (TMethod(FChangedHandlers[Index]).Code = TMethod(AHandler).Code) and
      (TMethod(FChangedHandlers[Index]).Data = TMethod(AHandler).Data) then
    begin
      if Index < High(FChangedHandlers) then
        Move(FChangedHandlers[Index + 1], FChangedHandlers[Index],
          (High(FChangedHandlers) - Index) * SizeOf(FChangedHandlers[0]));
      SetLength(FChangedHandlers, Length(FChangedHandlers) - 1);
      Exit;
    end;
end;

procedure TLazBleLclClient.NotifyChanged;
var
  Handler: TLazBleLclClientChangedEvent;
  Handlers: array of TLazBleLclClientChangedEvent;
  Current: TLazBleLclClientChangedEvent;
  Present: Boolean;
begin
  Handlers := Copy(FChangedHandlers);
  for Handler in Handlers do
  begin
    Present := False;
    for Current in FChangedHandlers do
      if (TMethod(Current).Code = TMethod(Handler).Code) and
        (TMethod(Current).Data = TMethod(Handler).Data) then
      begin
        Present := True;
        Break;
      end;
    if Present then Handler(Self);
  end;
end;

procedure TLazBleLclClient.RootComponentDestroying(
  const ARoot: TLazBleComponent);
begin
  if FLazBle <> ARoot then
    Exit;
  Inc(FGeneration);
  DetachCoreClient;
  ARoot.RemoveFreeNotification(Self);
  FLazBle := nil;
  NotifyChanged;
end;

procedure TLazBleLclClient.RootComponentShuttingDown(
  const ARoot: TLazBleComponent);
begin
  if FLazBle <> ARoot then
    Exit;
  DetachCoreClient;
end;

initialization
  RegisterClass(TLazBleComponent);
  RegisterClass(TLazBleLclClient);

finalization
  UnregisterClass(TLazBleLclClient);
  UnregisterClass(TLazBleComponent);

end.
