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

type
  TLazBleLclClient = class;

  TLazBleLclErrorEvent = procedure(Sender: TObject; const AErrorCode: Integer;
    const AErrorMessage: string) of object;

  TLazBleComponent = class(TComponent)
  private
    FBle: TLazBle;
    FScan: TLazBleLclScan;
    FAdapterId: string;
    FScanTimeoutMs: Cardinal;
    FOnScanStateChanged: TLazBleLclScanStateChangedEvent;
    FOnScanResult: TLazBleScanResultEvent;
    FOnScanCompleted: TLazBleLclScanCompletedEvent;
    FOnError: TLazBleLclErrorEvent;
    procedure Initialize(const ABle: TLazBle);
    function GetScanState: TLazBleLclScanState;
    function GetScanResults: TBleDeviceInfos;
    function GetLastErrorCode: Integer;
    function GetLastErrorMessage: string;
    procedure ScanStateChanged(Sender: TObject;
      const AState: TLazBleLclScanState);
    procedure ScanResult(Sender: TObject; const ADeviceId,
      ADeviceName: string; const ARssi: SmallInt);
    procedure ScanCompleted(Sender: TObject;
      const AState: TLazBleLclScanState);
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
    property ScanState: TLazBleLclScanState read GetScanState;
    property ScanResults: TBleDeviceInfos read GetScanResults;
    property LastErrorCode: Integer read GetLastErrorCode;
    property LastErrorMessage: string read GetLastErrorMessage;
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
    FOnConfigureClient: TNotifyEvent;
    FOnStateChanged: TLazBleClientStateChangedEvent;
    FOnConnected: TNotifyEvent;
    FOnDisconnected: TNotifyEvent;
    FOnError: TLazBleLclErrorEvent;
    procedure SetLazBle(const AValue: TLazBleComponent);
    procedure SetDeviceId(const AValue: string);
    function GetState: TLazBleClientState;
    procedure EnsureCoreClient;
    procedure RemoveDisconnectedCoreClient;
    procedure DetachCoreClient;
    procedure CoreStateChanged(Sender: TObject;
      const AState: TLazBleClientState);
    procedure ConnectCompleted(Sender: TObject);
    procedure DisconnectCompleted(Sender: TObject);
    procedure DispatchMessage(Sender: TObject;
      const AMessage: TLazBleLclDispatchMessage);
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
    property DeviceName: string read FDeviceName;
    property State: TLazBleClientState read GetState;
    property LastErrorCode: Integer read FLastErrorCode;
    property LastErrorMessage: string read FLastErrorMessage;
    property CoreClient: TBleClient read FCoreClient;
  published
    property LazBle: TLazBleComponent read FLazBle write SetLazBle;
    property DeviceId: string read FDeviceId write SetDeviceId;
    property OnConfigureClient: TNotifyEvent read FOnConfigureClient
      write FOnConfigureClient;
    property OnStateChanged: TLazBleClientStateChangedEvent
      read FOnStateChanged write FOnStateChanged;
    property OnConnected: TNotifyEvent read FOnConnected write FOnConnected;
    property OnDisconnected: TNotifyEvent read FOnDisconnected
      write FOnDisconnected;
    property OnError: TLazBleLclErrorEvent read FOnError write FOnError;
  end;

implementation

type
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
begin
  if Assigned(FScan) then
  begin
    FScan.OnStateChanged := nil;
    FScan.OnResult := nil;
    FScan.OnCompleted := nil;
  end;
  FScan.Free;
  FScan := nil;
  FBle.Free;
  FBle := nil;
  inherited Destroy;
end;

function TLazBleComponent.CreateFacade: TLazBle;
begin
  Result := TLazBle.Create;
end;

procedure TLazBleComponent.Initialize(const ABle: TLazBle);
begin
  FBle := ABle;
  FScan := TLazBleLclScan.Create(FBle);
  FScan.OnStateChanged := @ScanStateChanged;
  FScan.OnResult := @ScanResult;
  FScan.OnCompleted := @ScanCompleted;
end;

procedure TLazBleComponent.StartScan;
begin
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
  Result := FScan.ErrorCode;
end;

function TLazBleComponent.GetLastErrorMessage: string;
begin
  Result := FScan.ErrorMessage;
end;

procedure TLazBleComponent.ScanStateChanged(Sender: TObject;
  const AState: TLazBleLclScanState);
var
  Handler: TLazBleLclScanStateChangedEvent;
begin
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
    ErrorHandler := FOnError;
    if Assigned(ErrorHandler) then
      ErrorHandler(Self, FScan.ErrorCode, FScan.ErrorMessage);
  end;

  CompletedHandler := FOnScanCompleted;
  if Assigned(CompletedHandler) then
    CompletedHandler(Self, AState);
end;

constructor TLazBleLclClient.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FDispatch := TLazBleLclDispatch.Create(@DispatchMessage);
end;

destructor TLazBleLclClient.Destroy;
var
  OldCoreClient: TBleClient;
begin
  FDispatch.Detach;
  OldCoreClient := FCoreClient;
  DetachCoreClient;
  if Assigned(OldCoreClient) and Assigned(FLazBle) and
    (OldCoreClient.State = lbcstDisconnected) then
    FLazBle.Facade.RemoveClient(OldCoreClient);
  if Assigned(FLazBle) then
    FLazBle.RemoveFreeNotification(Self);
  FLazBle := nil;
  FDispatch.Free;
  FDispatch := nil;
  inherited Destroy;
end;

procedure TLazBleLclClient.SetLazBle(const AValue: TLazBleComponent);
begin
  if FLazBle = AValue then
    Exit;
  RemoveDisconnectedCoreClient;
  if Assigned(FLazBle) then
    FLazBle.RemoveFreeNotification(Self);
  FLazBle := AValue;
  if Assigned(FLazBle) then
    FLazBle.FreeNotification(Self);
end;

procedure TLazBleLclClient.SetDeviceId(const AValue: string);
begin
  if FDeviceId = AValue then
    Exit;
  RemoveDisconnectedCoreClient;
  FDeviceId := AValue;
  FDeviceName := '';
end;

function TLazBleLclClient.GetState: TLazBleClientState;
begin
  if Assigned(FCoreClient) then
    Result := FCoreClient.State
  else
    Result := lbcstDisconnected;
end;

procedure TLazBleLclClient.EnsureCoreClient;
var
  Handler: TNotifyEvent;
begin
  if Assigned(FCoreClient) then
    Exit;
  if not Assigned(FLazBle) then
    raise EInvalidOperation.Create('LazBle component is not assigned');
  if FDeviceId = '' then
    raise EInvalidOperation.Create('BLE device is not selected');

  FCoreClient := FLazBle.Facade.CreateClient(FDeviceId);
  FCoreClient.OnStateChanged := @CoreStateChanged;
  try
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

procedure TLazBleLclClient.RemoveDisconnectedCoreClient;
var
  OldCoreClient: TBleClient;
begin
  if not Assigned(FCoreClient) then
    Exit;
  if FCoreClient.State <> lbcstDisconnected then
    raise EInvalidOperation.Create(
      'BLE device can only be changed while disconnected');
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
  end;
end;

procedure TLazBleLclClient.SelectDevice(const ADevice: TBleDeviceInfo);
begin
  SetDeviceId(ADevice.DeviceId);
  FDeviceName := ADevice.DeviceName;
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
end;

initialization
  RegisterClass(TLazBleComponent);
  RegisterClass(TLazBleLclClient);

finalization
  UnregisterClass(TLazBleLclClient);
  UnregisterClass(TLazBleComponent);

end.
