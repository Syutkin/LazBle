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
  LazBleLclDispatch,
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

  TLazBleComponent = class(TComponent)
  private
    FBle: TLazBle;
    FScan: TLazBleLclScan;
    FClients: TList;
    FAvailabilityDispatch: TLazBleLclDispatch;
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
    procedure AvailabilityDispatchMessage(Sender: TObject;
      const AMessage: TLazBleLclDispatchMessage);
    procedure SetAvailability(const AAvailability: TBleAvailability);
  protected
    function CreateFacade: TLazBle; virtual;
  public
    constructor Create(AOwner: TComponent); override; overload;
    constructor Create(AOwner: TComponent;
      const ABackend: ILazBleBackend); reintroduce; overload;
    destructor Destroy; override;
    procedure StartScan;
    procedure CancelScan;
    procedure ClearScanResults;
    procedure RefreshAvailability;
    procedure Shutdown;
    function CreateClient(const ADeviceId: string): TLazBleLclClient;
    function FindClient(const ADeviceId: string): TLazBleLclClient;
    procedure RemoveClient(const AClient: TLazBleLclClient);
    property ScanState: TLazBleLclScanState read GetScanState;
    property Availability: TBleAvailability read FAvailability;
    property ScanResults: TBleDeviceInfos read GetScanResults;
    property ScanController: TLazBleLclScan read FScan;
    property LastErrorCode: Integer read GetLastErrorCode;
    property LastErrorMessage: string read GetLastErrorMessage;
    property BackendInfo: TLazBleBackendInfo read GetBackendInfo;
    property ClientCount: Integer read GetClientCount;
    property Clients[const AIndex: Integer]: TLazBleLclClient
      read GetClient;
    property Facade: TLazBle read FBle;
  published
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

  TLazBleLclClient = class(TComponent)
  private
    FLazBle: TLazBleComponent;
    FDeviceId: string;
    FDeviceName: string;
    FCoreClient: TBleClient;
    FDispatch: TLazBleLclDispatch;
    FConnectOperation: IBleOperation;
    FDisconnectOperation: IBleOperation;
    FLastErrorCode: Integer;
    FLastErrorMessage: string;
    FAutoReconnect: Boolean;
    FReconnectOptions: TLazBleReconnectSettings;
    FOnConfigureClient: TNotifyEvent;
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
    procedure DispatchMessage(Sender: TObject;
      const AMessage: TLazBleLclDispatchMessage);
    procedure NotifyChanged;
    procedure RootComponentShuttingDown(const ARoot: TLazBleComponent);
    procedure RootComponentDestroying(const ARoot: TLazBleComponent);
  protected
    procedure Notification(AComponent: TComponent;
      Operation: TOperation); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SelectDevice(const ADevice: TBleDeviceInfo);
    procedure AddProfile(const AProfile: TBleGattProfile;
      const ARequired: Boolean = True);
    procedure Connect;
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
    property CoreClient: TBleClient read FCoreClient;
  published
    property LazBle: TLazBleComponent read FLazBle write SetLazBle;
    property DeviceId: string read FDeviceId write SetDeviceId;
    property AutoReconnect: Boolean read FAutoReconnect
      write SetAutoReconnect default False;
    property ReconnectOptions: TLazBleReconnectSettings
      read FReconnectOptions write SetReconnectOptions;
    property OnConfigureClient: TNotifyEvent read FOnConfigureClient
      write FOnConfigureClient;
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

type
  TLazBleLclAvailabilityMessage = class(TLazBleLclDispatchMessage)
  private
    FOperationState: TLazBleOperationState;
    FAvailability: TBleAvailability;
    FErrorCode: Integer;
    FErrorMessage: string;
  public
    constructor Create(const AOperationState: TLazBleOperationState;
      const AAvailability: TBleAvailability; const AErrorCode: Integer;
      const AErrorMessage: string);
    function Clone: TLazBleLclDispatchMessage; override;
    property OperationState: TLazBleOperationState read FOperationState;
    property Availability: TBleAvailability read FAvailability;
    property ErrorCode: Integer read FErrorCode;
    property ErrorMessage: string read FErrorMessage;
  end;

  TLazBleLclClientOperationKind = (
    lblcokConnect,
    lblcokDisconnect
  );

  TLazBleLclClientStateMessage = class(TLazBleLclDispatchMessage)
  private
    FState: TLazBleClientState;
  public
    constructor Create(const AState: TLazBleClientState);
    function Clone: TLazBleLclDispatchMessage; override;
    property State: TLazBleClientState read FState;
  end;

  TLazBleLclClientCompletedMessage = class(TLazBleLclDispatchMessage)
  private
    FKind: TLazBleLclClientOperationKind;
    FState: TLazBleOperationState;
    FErrorCode: Integer;
    FErrorMessage: string;
  public
    constructor Create(const AKind: TLazBleLclClientOperationKind;
      const AState: TLazBleOperationState; const AErrorCode: Integer;
      const AErrorMessage: string);
    function Clone: TLazBleLclDispatchMessage; override;
    property Kind: TLazBleLclClientOperationKind read FKind;
    property State: TLazBleOperationState read FState;
    property ErrorCode: Integer read FErrorCode;
    property ErrorMessage: string read FErrorMessage;
  end;

constructor TLazBleLclAvailabilityMessage.Create(
  const AOperationState: TLazBleOperationState;
  const AAvailability: TBleAvailability; const AErrorCode: Integer;
  const AErrorMessage: string);
begin
  inherited Create;
  FOperationState := AOperationState;
  FAvailability := AAvailability;
  FErrorCode := AErrorCode;
  FErrorMessage := AErrorMessage;
end;

function TLazBleLclAvailabilityMessage.Clone: TLazBleLclDispatchMessage;
begin
  Result := TLazBleLclAvailabilityMessage.Create(FOperationState,
    FAvailability, FErrorCode, FErrorMessage);
end;

constructor TLazBleLclClientStateMessage.Create(
  const AState: TLazBleClientState);
begin
  inherited Create;
  FState := AState;
end;

function TLazBleLclClientStateMessage.Clone: TLazBleLclDispatchMessage;
begin
  Result := TLazBleLclClientStateMessage.Create(FState);
end;

constructor TLazBleLclClientCompletedMessage.Create(
  const AKind: TLazBleLclClientOperationKind;
  const AState: TLazBleOperationState; const AErrorCode: Integer;
  const AErrorMessage: string);
begin
  inherited Create;
  FKind := AKind;
  FState := AState;
  FErrorCode := AErrorCode;
  FErrorMessage := AErrorMessage;
end;

function TLazBleLclClientCompletedMessage.Clone:
  TLazBleLclDispatchMessage;
begin
  Result := TLazBleLclClientCompletedMessage.Create(FKind, FState,
    FErrorCode, FErrorMessage);
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
begin
  Shutdown;
  if Assigned(FClients) then
    for Index := FClients.Count - 1 downto 0 do
      TLazBleLclClient(FClients[Index]).RootComponentDestroying(Self);
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
  FAvailabilityDispatch.Free;
  FAvailabilityDispatch := nil;
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
  FAvailabilityDispatch := TLazBleLclDispatch.Create(
    @AvailabilityDispatchMessage);
  FScan := TLazBleLclScan.Create(FBle);
  FScan.OnStateChanged := @ScanStateChanged;
  FScan.OnResult := @ScanResult;
  FScan.OnCompleted := @ScanCompleted;
end;

procedure TLazBleComponent.EnsureOperational;
begin
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
  FAvailabilityOperation := FBle.CheckAvailabilityAsync(FAdapterId);
  FAvailabilityOperation.OnCompleted := @AvailabilityCompleted;
end;

procedure TLazBleComponent.Shutdown;
var
  Index: Integer;
begin
  if FShutdownStarted then
    Exit;
  FShutdownStarted := True;
  if Assigned(FAvailabilityDispatch) then
    FAvailabilityDispatch.Detach;
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
    for Index := FClients.Count - 1 downto 0 do
      TLazBleLclClient(FClients[Index]).RootComponentShuttingDown(Self);
  if Assigned(FBle) then
    FShutdownOperation := FBle.ShutdownAsync;
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
  if AState in [lblssTimedOut, lblssFailed] then
  begin
    FLastErrorCode := FScan.ErrorCode;
    FLastErrorMessage := FScan.ErrorMessage;
    ErrorHandler := FOnError;
    if Assigned(ErrorHandler) then
      ErrorHandler(Self, FLastErrorCode, FLastErrorMessage);
  end;

  CompletedHandler := FOnScanCompleted;
  if Assigned(CompletedHandler) then
    CompletedHandler(Self, AState);
end;

procedure TLazBleComponent.AvailabilityCompleted(Sender: TObject);
var
  Message: TLazBleLclAvailabilityMessage;
  Operation: TBleAvailabilityOperation;
begin
  if not (Sender is TBleAvailabilityOperation) then
    Exit;
  Operation := TBleAvailabilityOperation(Sender);
  Message := TLazBleLclAvailabilityMessage.Create(Operation.State,
    Operation.Availability, Operation.ErrorCode, Operation.ErrorMessage);
  try
    FAvailabilityDispatch.Queue(Message);
  finally
    Message.Free;
  end;
end;

procedure TLazBleComponent.AvailabilityDispatchMessage(Sender: TObject;
  const AMessage: TLazBleLclDispatchMessage);
var
  AvailabilityMessage: TLazBleLclAvailabilityMessage;
  ErrorHandler: TLazBleLclErrorEvent;
begin
  if not (AMessage is TLazBleLclAvailabilityMessage) then
    Exit;
  AvailabilityMessage := TLazBleLclAvailabilityMessage(AMessage);
  FAvailabilityOperation := nil;
  if AvailabilityMessage.OperationState = lbopSucceeded then
    SetAvailability(AvailabilityMessage.Availability)
  else if AvailabilityMessage.OperationState = lbopCancelled then
    SetAvailability(lbaUnknown)
  else
  begin
    FLastErrorCode := AvailabilityMessage.ErrorCode;
    FLastErrorMessage := AvailabilityMessage.ErrorMessage;
    SetAvailability(lbaUnavailable);
    ErrorHandler := FOnError;
    if Assigned(ErrorHandler) then
      ErrorHandler(Self, FLastErrorCode, FLastErrorMessage);
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
  Handler := FOnAvailabilityChanged;
  if Assigned(Handler) then
    Handler(Self, FAvailability);
end;

constructor TLazBleLclClient.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FReconnectOptions := TLazBleReconnectSettings.Create;
  FReconnectOptions.FOnChange := @ReconnectSettingsChanged;
  FDispatch := TLazBleLclDispatch.Create(@DispatchMessage);
end;

destructor TLazBleLclClient.Destroy;
var
  OldCoreClient: TBleClient;
begin
  FDispatch.Detach;
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
  FDispatch.Free;
  FDispatch := nil;
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
  if not Assigned(FCoreClient) then
    Exit;
  if not (FCoreClient.State in [lbcstDisconnected, lbcstError]) then
    raise EInvalidOperation.Create(
      'BLE device can only be changed while disconnected or in error');
  FDispatch.NextGeneration;
  OldCoreClient := FCoreClient;
  DetachCoreClient;
  if Assigned(FLazBle) then
    FLazBle.Facade.RemoveClient(OldCoreClient);
end;

procedure TLazBleLclClient.DetachCoreClient;
begin
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
    FDispatch.NextGeneration;
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
  FLastErrorCode := 0;
  FLastErrorMessage := '';
  FDispatch.NextGeneration;
  FConnectOperation := FCoreClient.ConnectAsync;
  FConnectOperation.OnCompleted := @ConnectCompleted;
end;

procedure TLazBleLclClient.Disconnect;
begin
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
  FDispatch.NextGeneration;
  FDisconnectOperation := FCoreClient.DisconnectAsync;
  FDisconnectOperation.OnCompleted := @DisconnectCompleted;
end;

procedure TLazBleLclClient.CoreStateChanged(Sender: TObject;
  const AState: TLazBleClientState);
var
  Message: TLazBleLclClientStateMessage;
begin
  Message := TLazBleLclClientStateMessage.Create(AState);
  try
    FDispatch.Queue(Message);
  finally
    Message.Free;
  end;
end;

procedure TLazBleLclClient.ConnectCompleted(Sender: TObject);
var
  Message: TLazBleLclClientCompletedMessage;
  Operation: TBleOperation;
begin
  if not (Sender is TBleOperation) then
    Exit;
  Operation := TBleOperation(Sender);
  Message := TLazBleLclClientCompletedMessage.Create(lblcokConnect,
    Operation.State, Operation.ErrorCode, Operation.ErrorMessage);
  try
    FDispatch.Queue(Message);
  finally
    Message.Free;
  end;
end;

procedure TLazBleLclClient.DisconnectCompleted(Sender: TObject);
var
  Message: TLazBleLclClientCompletedMessage;
  Operation: TBleOperation;
begin
  if not (Sender is TBleOperation) then
    Exit;
  Operation := TBleOperation(Sender);
  Message := TLazBleLclClientCompletedMessage.Create(lblcokDisconnect,
    Operation.State, Operation.ErrorCode, Operation.ErrorMessage);
  try
    FDispatch.Queue(Message);
  finally
    Message.Free;
  end;
end;

procedure TLazBleLclClient.DispatchMessage(Sender: TObject;
  const AMessage: TLazBleLclDispatchMessage);
var
  CompletedHandler: TNotifyEvent;
  CompletedMessage: TLazBleLclClientCompletedMessage;
  ErrorHandler: TLazBleLclErrorEvent;
  StateHandler: TLazBleClientStateChangedEvent;
begin
  if AMessage is TLazBleLclClientStateMessage then
  begin
    StateHandler := FOnStateChanged;
    if Assigned(StateHandler) then
      StateHandler(Self, TLazBleLclClientStateMessage(AMessage).State);
    NotifyChanged;
    Exit;
  end;
  if not (AMessage is TLazBleLclClientCompletedMessage) then
    Exit;

  CompletedMessage := TLazBleLclClientCompletedMessage(AMessage);
  if CompletedMessage.Kind = lblcokConnect then
    FConnectOperation := nil
  else
    FDisconnectOperation := nil;

  if CompletedMessage.State = lbopSucceeded then
  begin
    if CompletedMessage.Kind = lblcokConnect then
      CompletedHandler := FOnConnected
    else
      CompletedHandler := FOnDisconnected;
    if Assigned(CompletedHandler) then
      CompletedHandler(Self);
  end
  else if CompletedMessage.State in [lbopFailed, lbopTimedOut] then
  begin
    FLastErrorCode := CompletedMessage.ErrorCode;
    FLastErrorMessage := CompletedMessage.ErrorMessage;
    ErrorHandler := FOnError;
    if Assigned(ErrorHandler) then
      ErrorHandler(Self, FLastErrorCode, FLastErrorMessage);
  end;
  NotifyChanged;
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
begin
  Handlers := Copy(FChangedHandlers);
  for Handler in Handlers do
    if Assigned(Handler) then
      Handler(Self);
end;

procedure TLazBleLclClient.RootComponentDestroying(
  const ARoot: TLazBleComponent);
begin
  if FLazBle <> ARoot then
    Exit;
  FDispatch.NextGeneration;
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
  FDispatch.Detach;
  DetachCoreClient;
end;

initialization
  RegisterClass(TLazBleComponent);
  RegisterClass(TLazBleLclClient);

finalization
  UnregisterClass(TLazBleLclClient);
  UnregisterClass(TLazBleComponent);

end.
