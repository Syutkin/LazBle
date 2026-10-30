unit LazBleGattSession;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  LazBleTypes,
  LazBleBackend,
  LazBleOperation,
  LazBleGattOperation,
  LazBleGattSubscription;

type
  TLazBleSessionState = (
    lbssDisconnected,
    lbssConnecting,
    lbssDiscovering,
    lbssConnected,
    lbssDisconnecting,
    lbssError
  );

  TLazBleSessionStateChangedEvent = procedure(Sender: TObject;
    const AState: TLazBleSessionState) of object;
  TLazBleSessionStateChangedEvents = array of
    TLazBleSessionStateChangedEvent;

  TLazBleSubmitCommand = function(
    const ACommand: TLazBleBackendCommand;
    const ACompletion: ILazBleRequestCompletion = nil;
    const AValues: ILazBleValueSink = nil;
    const AScan: ILazBleScanSink = nil;
    const ALink: ILazBleLinkObserver = nil): TBleOperationId of object;
  TLazBleCancelOperation = procedure(
    const AOperationId: TBleOperationId) of object;

  { Device GATT session used by TBleClient and profiles. Services reflect the
    current connection as read-only upstream records and are invalidated when it ends. }
  TBleGattSession = class
  private
    FLink: ILazBleLinkObserver;
    FLinkObject: TObject;
    FDeviceId: string;
    FState: TLazBleSessionState;
    FShuttingDown: Boolean;
    FGeneration: QWord;
    FConnectOperationId: TBleOperationId;
    FDiscoveryOperationId: TBleOperationId;
    FDisconnectOperationId: TBleOperationId;
    FConnectWorkflow, FDisconnectWorkflow: IBleOperation;
    FConnectWorkflowObject, FDisconnectWorkflowObject: TBleOperation;
    FSubmitCommand: TLazBleSubmitCommand;
    FCancelOperation: TLazBleCancelOperation;
    FOperations: TList;
    FSubscriptions: TList;
    FServices: TLazBleGattServices;
    FConnectionEstablished, FLastOperationCancelled, FLastOperationFailed: Boolean;
    FErrorCode: Integer;
    FErrorMessage: string;
    FOnStateChanged: TLazBleSessionStateChangedEvent;
    FStateChangedHandlers: TLazBleSessionStateChangedEvents;
    procedure SetState(const AState: TLazBleSessionState);
    function GetState: TLazBleSessionState;
    function GetGeneration: QWord;
    function GetServices: TLazBleGattServices;
    function GetErrorCode: Integer;
    function GetErrorMessage: string;
    function GetOnStateChanged: TLazBleSessionStateChangedEvent;
    procedure SetOnStateChanged(
      const AHandler: TLazBleSessionStateChangedEvent);
    function SubmitGattCommand(const ACommand: TLazBleBackendCommand):
      IBleGattOperation;
    function DescriptorCommand(const AKind: TLazBleBackendCommandKind;
      const AServiceUuid, ACharacteristicUuid, ADescriptorUuid: string;
      const AValue: TBytes): IBleGattOperation;
    procedure OperationCancelled(Sender: TObject);
    procedure GattCompleted(Sender: TObject);
    procedure SubscriptionRetired(Sender: TObject);
    function UnsubscribeSubscription(
      const ASubscription: TBleSubscription): IBleGattOperation;
    procedure InvalidateGattState(const AForce: Boolean = False);
  protected
    constructor Create(const ADeviceId: string;
      const ASubmitCommand: TLazBleSubmitCommand;
      const ACancelOperation: TLazBleCancelOperation);
    function Connect: TBleOperationId;
    function Disconnect: TBleOperationId;
    function BeginConnect: IBleOperation;
    function BeginDisconnect: IBleOperation;
    procedure CancelConnect;
    procedure CancelDisconnect;
    procedure HandleLinkChanged(const AConnected: Boolean; const AGeneration: QWord);
    procedure HandleBackendShutdown;
    procedure PrepareShutdown;
    procedure AddStateChangedHandler(
      const AHandler: TLazBleSessionStateChangedEvent);
    procedure RemoveStateChangedHandler(
      const AHandler: TLazBleSessionStateChangedEvent);
  public
    destructor Destroy; override;
    { UUID-based requests return failed operations when the session or
      characteristic cannot serve the request. }
    function ReadAsync(const AServiceUuid, ACharacteristicUuid: string):
      IBleGattOperation;
    function WriteAsync(const AServiceUuid, ACharacteristicUuid: string;
      const AValue: TBytes; const AWriteMode: TLazBleWriteMode):
      IBleGattOperation;
    function ReadDescriptorAsync(const AServiceUuid, ACharacteristicUuid,
      ADescriptorUuid: string): IBleGattOperation;
    function WriteDescriptorAsync(const AServiceUuid, ACharacteristicUuid,
      ADescriptorUuid: string; const AValue: TBytes): IBleGattOperation;
    function SubscribeAsync(const AServiceUuid, ACharacteristicUuid: string;
      const AMode: TLazBleSubscriptionMode = lbsmNotify):
      IBleSubscription;
    { Query the currently discovered service tree. }
    function HasService(const AServiceUuid: string): Boolean;
    function TryGetCharacteristic(const AServiceUuid,
      ACharacteristicUuid: string;
      out ACharacteristic: TLazBleGattCharacteristic): Boolean;
    property DeviceId: string read FDeviceId;
    property Generation: QWord read GetGeneration;
    property State: TLazBleSessionState read GetState;
    property Services: TLazBleGattServices read GetServices;
    property LastOperationFailed: Boolean read FLastOperationFailed;
    property LastOperationCancelled: Boolean read FLastOperationCancelled;
    property ErrorCode: Integer read GetErrorCode;
    property ErrorMessage: string read GetErrorMessage;
    property OnStateChanged: TLazBleSessionStateChangedEvent
      read GetOnStateChanged write SetOnStateChanged;
  end;

implementation

type
  TSessionLink = class(TInterfacedObject, ILazBleLinkObserver)
    Session: TBleGattSession;
    constructor Create(ASession: TBleGattSession);
    procedure LinkChanged(const AConnected: Boolean; const AGeneration: QWord);
  end;

  TSessionWorkflow = class(TBleOperation)
  private
    FSession: TBleGattSession;
    FGeneration: QWord;
    FKind: TLazBleBackendCommandKind;
    FId: TBleOperationId;
    procedure CancelRequest(Sender: TObject);
    procedure Finish(const AResult: TLazBleRequestResult);
  public
    constructor Create(ASession: TBleGattSession;
      AKind: TLazBleBackendCommandKind);
    procedure Start(AKind: TLazBleBackendCommandKind);
    procedure CompleteRequest(const AResult: TLazBleRequestResult); override;
    procedure Detach;
  end;

  TBleGattOperationAccess = class(TBleGattOperation)
  public
    constructor CreateRequestInternal(const AKind: TLazBleBackendCommandKind;
      const AOnCancel: TLazBleOperationCancelEvent; const AGeneration: QWord;
      const AOnFinishing: TLazBleOperationCompletedEvent);
    procedure Bind(const AOperationId: TBleOperationId);
    constructor CreateFailed(const AKind: TLazBleBackendCommandKind;
      const ACode: Integer; const AText: string);
    procedure CancelWithoutBackend;
    procedure DetachFromSession;
    function OperationId: TBleOperationId;
    function OperationKind: TLazBleBackendCommandKind;
  end;

  TBleSubscriptionAccess = class(TBleSubscription)
  public
    constructor CreateRequestInternal(const AGeneration: QWord;
      const AUnsubscribe: TLazBleUnsubscribe; const AOnRetired: TNotifyEvent);
    procedure Bind(const AOperationId: TBleOperationId);
    constructor CreateFailed(const ACode: Integer; const AText: string);
    procedure InvalidateInternal(const AForce: Boolean = False);
    procedure DetachCallbacksInternal;
    function CleanupPendingInternal: Boolean;
    procedure BeginShutdownInternal;
    procedure DetachFromSession;
    function OperationId: TBleOperationId;
    function SubscriptionId: TBleSubscriptionId;
  end;

  TBleGattOperationEntry = class
  public
    Operation: IBleGattOperation;
    Instance: TBleGattOperation;
  end;

  TBleSubscriptionEntry = class
  public
    Subscription: IBleSubscription;
    Instance: TBleSubscription;
  end;

  TBleGattOperationInterfaces = array of IBleGattOperation;
  TBleGattOperationObjects = array of TBleGattOperation;
  TBleSubscriptionInterfaces = array of IBleSubscription;
  TBleSubscriptionObjects = array of TBleSubscription;

constructor TSessionLink.Create(ASession: TBleGattSession);
begin
  inherited Create;
  Session := ASession;
end;

procedure TSessionLink.LinkChanged(const AConnected: Boolean; const AGeneration: QWord);
begin
  LazBleRequireMainThread;
  if Session <> nil then Session.HandleLinkChanged(AConnected, AGeneration);
end;

constructor TSessionWorkflow.Create(ASession: TBleGattSession;
  AKind: TLazBleBackendCommandKind);
begin
  inherited Create(@CancelRequest);
  FSession := ASession;
  FGeneration := ASession.Generation;
  FKind := AKind;
end;

procedure TSessionWorkflow.Start(AKind: TLazBleBackendCommandKind);
var Command: TLazBleBackendCommand; R: TLazBleRequestResult;
begin
  FKind := AKind;
  Command := Default(TLazBleBackendCommand);
  Command.Kind := AKind;
  Command.DeviceId := FSession.DeviceId;
  Command.Generation := FGeneration;
  FId := InvalidBleOperationId;
  if Assigned(FSession.FSubmitCommand) then
    FId := FSession.FSubmitCommand(Command, Self, nil, nil, FSession.FLink);
  if FId = InvalidBleOperationId then
  begin
    R := Default(TLazBleRequestResult);
    R.Status := lbrsFailed; R.ErrorCode := LazBleErrorInvalidState;
    R.ErrorMessage := 'Could not submit BLE session request';
    CompleteRequest(R);
  end;
end;

procedure TSessionWorkflow.CancelRequest(Sender: TObject);
begin
  if (FSession <> nil) and Assigned(FSession.FCancelOperation) then
    FSession.FCancelOperation(FId);
end;

procedure TSessionWorkflow.Finish(const AResult: TLazBleRequestResult);
begin
  if (FSession <> nil) and (FGeneration = FSession.Generation) then
  begin
    FSession.FLastOperationFailed := AResult.Status = lbrsFailed;
    FSession.FLastOperationCancelled := AResult.Status = lbrsCancelled;
    FSession.FErrorCode := AResult.ErrorCode;
    FSession.FErrorMessage := AResult.ErrorMessage;
  end;
  FSession := nil;
  case AResult.Status of
    lbrsSucceeded: Complete(lbopSucceeded);
    lbrsFailed: Complete(lbopFailed, AResult.ErrorCode, AResult.ErrorMessage);
    lbrsCancelled: Complete(lbopCancelled, AResult.ErrorCode, AResult.ErrorMessage);
  end;
end;

procedure TSessionWorkflow.CompleteRequest(const AResult: TLazBleRequestResult);
var S: TBleGattSession; R: TLazBleRequestResult; KeepAlive: IBleOperation;
begin
  LazBleRequireMainThread;
  KeepAlive := Self;
  if State <> lbopPending then Exit;
  S := FSession;
  R := AResult;
  if (S = nil) or (FGeneration <> S.Generation) then
  begin
    Finish(R);
    Exit;
  end;
  if S.FShuttingDown and (FKind <> lbckDisconnect) then R.Status := lbrsCancelled;
  S.FLastOperationCancelled := R.Status = lbrsCancelled;
  S.FLastOperationFailed := R.Status = lbrsFailed;
  S.FErrorCode := R.ErrorCode;
  S.FErrorMessage := R.ErrorMessage;
  if R.Status <> lbrsSucceeded then
  begin
    if (FKind <> lbckDisconnect) and (S.State = lbssDisconnecting) then
    begin
      { An explicit disconnect owns the current session state. }
    end
    else if R.Status = lbrsFailed then S.SetState(lbssError)
    else if (FKind = lbckDisconnect) and S.FConnectionEstablished then S.SetState(lbssConnected)
    else if S.FConnectionEstablished then S.SetState(lbssError)
    else S.SetState(lbssDisconnected);
    Finish(R);
    Exit;
  end;
  case FKind of
    lbckConnect:
      if S.State = lbssConnecting then
      begin
        S.FConnectionEstablished := True;
        Start(lbckDiscoverServices);
        if State = lbopPending then
        begin
          S.FDiscoveryOperationId := FId;
          S.SetState(lbssDiscovering);
        end;
        Exit;
      end;
    lbckDiscoverServices:
      if (S.State = lbssDiscovering) and S.FConnectionEstablished then
      begin
        S.FServices := R.Services;
        S.SetState(lbssConnected);
        if (S.State = lbssConnected) and (S.Generation = FGeneration) then
        begin
          Finish(R);
          Exit;
        end;
      end;
    lbckDisconnect:
      begin
        S.FConnectionEstablished := False;
        S.InvalidateGattState;
        S.SetState(lbssDisconnected);
        Finish(R);
        Exit;
      end;
  end;
  R.Status := lbrsFailed;
  R.ErrorCode := LazBleErrorDeviceDisconnected;
  R.ErrorMessage := 'BLE session ended before connection was ready';
  Finish(R);
end;

procedure TSessionWorkflow.Detach;
begin
  FSession := nil;
  OnCompleted := nil;
  Complete(lbopCancelled);
end;

constructor TBleGattOperationAccess.CreateFailed(const AKind: TLazBleBackendCommandKind;
  const ACode: Integer; const AText: string);
begin
  inherited CreatePending(AKind);
  Complete(lbopFailed, ACode, AText);
end;

constructor TBleGattOperationAccess.CreateRequestInternal(
  const AKind: TLazBleBackendCommandKind;
  const AOnCancel: TLazBleOperationCancelEvent; const AGeneration: QWord;
  const AOnFinishing: TLazBleOperationCompletedEvent);
begin
  inherited CreateRequest(AKind, AOnCancel, AGeneration);
  OnFinishing := AOnFinishing;
end;

procedure TBleGattOperationAccess.Bind(const AOperationId: TBleOperationId);
begin
  BindRequest(AOperationId);
end;

constructor TBleSubscriptionAccess.CreateFailed(const ACode: Integer; const AText: string);
begin
  inherited CreateFailed(ACode, AText);
end;

constructor TBleSubscriptionAccess.CreateRequestInternal(const AGeneration: QWord;
  const AUnsubscribe: TLazBleUnsubscribe; const AOnRetired: TNotifyEvent);
begin
  inherited CreateRequest(AGeneration, AUnsubscribe, AOnRetired);
end;

procedure TBleSubscriptionAccess.Bind(const AOperationId: TBleOperationId);
begin BindRequest(AOperationId); end;

procedure TBleGattOperationAccess.CancelWithoutBackend;
begin
  LazBleRequireMainThread;
  CancelLocally;
end;

function TBleGattOperationAccess.OperationKind: TLazBleBackendCommandKind;
begin Result := GetKind; end;

procedure TBleGattOperationAccess.DetachFromSession;
begin
  LazBleRequireMainThread;
  DetachOwner;
end;

function TBleGattOperationAccess.OperationId: TBleOperationId;
begin
  LazBleRequireMainThread;
  Result := GetOperationId;
end;

procedure TBleSubscriptionAccess.InvalidateInternal(const AForce: Boolean);
begin Invalidate(AForce); end;
procedure TBleSubscriptionAccess.DetachCallbacksInternal;
begin DetachCallbacks; end;
function TBleSubscriptionAccess.CleanupPendingInternal: Boolean;
begin Result := CleanupPending; end;

procedure TBleSubscriptionAccess.BeginShutdownInternal;
begin
  BeginShutdown;
end;

procedure TBleSubscriptionAccess.DetachFromSession;
begin
  LazBleRequireMainThread;
  DetachOwner;
end;

function TBleSubscriptionAccess.OperationId: TBleOperationId;
begin
  LazBleRequireMainThread;
  Result := GetOperationId;
end;

function TBleSubscriptionAccess.SubscriptionId: TBleSubscriptionId;
begin
  LazBleRequireMainThread;
  Result := GetSubscriptionId;
end;

function TBleGattSession.GetServices: TLazBleGattServices;
begin
  LazBleRequireMainThread;
  Result := FServices;
end;

function TBleGattSession.HasService(const AServiceUuid: string): Boolean;
var
  Service: TLazBleGattService;
begin
  LazBleRequireMainThread;
  for Service in FServices do
    if SameText(UTF8Encode(Service.Uuid), AServiceUuid) then
      Exit(True);
  Result := False;
end;

function TBleGattSession.TryGetCharacteristic(const AServiceUuid,
  ACharacteristicUuid: string;
  out ACharacteristic: TLazBleGattCharacteristic): Boolean;
var
  Characteristic: TLazBleGattCharacteristic;
  Service: TLazBleGattService;
begin
  LazBleRequireMainThread;
  ACharacteristic := Default(TLazBleGattCharacteristic);
  for Service in FServices do
    if SameText(UTF8Encode(Service.Uuid), AServiceUuid) then
      for Characteristic in Service.Characteristics do
        if SameText(UTF8Encode(Characteristic.Uuid), ACharacteristicUuid) then
        begin
          ACharacteristic := Characteristic;
          Exit(True);
        end;
  Result := False;
end;

function TBleGattSession.GetState: TLazBleSessionState;
begin
  LazBleRequireMainThread;
  Result := FState;
end;

function TBleGattSession.GetErrorCode: Integer;
begin
  LazBleRequireMainThread;
  Result := FErrorCode;
end;

function TBleGattSession.GetErrorMessage: string;
begin
  LazBleRequireMainThread;
  Result := FErrorMessage;
end;

function TBleGattSession.GetGeneration: QWord;
begin
  LazBleRequireMainThread;
  Result := FGeneration;
end;

function TBleGattSession.GetOnStateChanged:
  TLazBleSessionStateChangedEvent;
begin
  LazBleRequireMainThread;
  Result := FOnStateChanged;
end;

procedure TBleGattSession.SetOnStateChanged(
  const AHandler: TLazBleSessionStateChangedEvent);
begin
  LazBleRequireMainThread;
  FOnStateChanged := AHandler;
end;

procedure TBleGattSession.SetState(const AState: TLazBleSessionState);
var
  Handler: TLazBleSessionStateChangedEvent;
  Handlers: TLazBleSessionStateChangedEvents;
  DeliveryGeneration: QWord;
begin
  LazBleRequireMainThread;
  if FState = AState then
    Exit;
  FState := AState;
  DeliveryGeneration := FGeneration;
  Handler := FOnStateChanged;
  Handlers := Copy(FStateChangedHandlers);
  if Assigned(Handler) then
    Handler(Self, AState);
  for Handler in Handlers do
  begin
    if (FState <> AState) or (FGeneration <> DeliveryGeneration) then Break;
    if Assigned(Handler) then Handler(Self, AState);
  end;
end;

function SameStateChangedHandler(const AFirst,
  ASecond: TLazBleSessionStateChangedEvent): Boolean;
begin
  Result := (TMethod(AFirst).Code = TMethod(ASecond).Code) and
    (TMethod(AFirst).Data = TMethod(ASecond).Data);
end;

procedure TBleGattSession.AddStateChangedHandler(
  const AHandler: TLazBleSessionStateChangedEvent);
var
  Handler: TLazBleSessionStateChangedEvent;
  Index: Integer;
begin
  LazBleRequireMainThread;
  if not Assigned(AHandler) then
    Exit;
  for Handler in FStateChangedHandlers do
    if SameStateChangedHandler(Handler, AHandler) then
      Exit;
  Index := Length(FStateChangedHandlers);
  SetLength(FStateChangedHandlers, Index + 1);
  FStateChangedHandlers[Index] := AHandler;
end;

procedure TBleGattSession.RemoveStateChangedHandler(
  const AHandler: TLazBleSessionStateChangedEvent);
var
  Index: Integer;
  MoveIndex: Integer;
begin
  LazBleRequireMainThread;
  for Index := 0 to High(FStateChangedHandlers) do
    if SameStateChangedHandler(FStateChangedHandlers[Index], AHandler) then
    begin
      for MoveIndex := Index to High(FStateChangedHandlers) - 1 do
        FStateChangedHandlers[MoveIndex] :=
          FStateChangedHandlers[MoveIndex + 1];
      SetLength(FStateChangedHandlers,
        Length(FStateChangedHandlers) - 1);
      Exit;
    end;
end;

constructor TBleGattSession.Create(const ADeviceId: string;
  const ASubmitCommand: TLazBleSubmitCommand;
  const ACancelOperation: TLazBleCancelOperation);
begin
  inherited Create;
  FDeviceId := ADeviceId;
  FLinkObject := TSessionLink.Create(Self);
  FLink := TSessionLink(FLinkObject);
  FSubmitCommand := ASubmitCommand;
  FCancelOperation := ACancelOperation;
  FState := lbssDisconnected;
  FOperations := TList.Create;
  FSubscriptions := TList.Create;
end;

destructor TBleGattSession.Destroy;
var I: Integer;
begin
  TSessionLink(FLinkObject).Session := nil;
  if FConnectWorkflow <> nil then TSessionWorkflow(FConnectWorkflowObject).Detach;
  if FDisconnectWorkflow <> nil then TSessionWorkflow(FDisconnectWorkflowObject).Detach;
  for I := 0 to FOperations.Count - 1 do
    TBleGattOperationEntry(FOperations[I]).Operation.OnCompleted := nil;
  for I := 0 to FSubscriptions.Count - 1 do
    TBleSubscriptionAccess(TBleSubscriptionEntry(FSubscriptions[I]).Instance).DetachCallbacksInternal;
  InvalidateGattState(True);
  SetOnStateChanged(nil);
  FStateChangedHandlers := nil;
  FSubscriptions.Free;
  FOperations.Free;
  inherited Destroy;
end;

function TBleGattSession.SubmitGattCommand(
  const ACommand: TLazBleBackendCommand): IBleGattOperation;
var
  Entry: TBleGattOperationEntry;
  Operation: TBleGattOperationAccess;
  OperationId: TBleOperationId;
begin
  LazBleRequireMainThread;
  Operation := TBleGattOperationAccess.CreateRequestInternal(ACommand.Kind,
    @OperationCancelled, ACommand.Generation, @GattCompleted);
  Result := Operation;
  Entry := TBleGattOperationEntry.Create;
  Entry.Instance := Operation;
  Entry.Operation := Result;
  FOperations.Add(Entry);
  OperationId := InvalidBleOperationId;
  if (State = lbssConnected) and not FShuttingDown and Assigned(FSubmitCommand) then
    OperationId := FSubmitCommand(ACommand, Operation);
  Operation.Bind(OperationId);
end;

procedure TBleGattSession.OperationCancelled(Sender: TObject);
var
  OperationId: TBleOperationId;
begin
  LazBleRequireMainThread;
  OperationId := TBleGattOperationAccess(Sender).OperationId;
  if (OperationId <> InvalidBleOperationId) and Assigned(FCancelOperation) then
    FCancelOperation(OperationId)
  else
    TBleGattOperationAccess(Sender).CancelWithoutBackend;
end;

procedure TBleGattSession.GattCompleted(Sender: TObject);
var I: Integer; Entry: TBleGattOperationEntry; Operation: TBleGattOperationAccess;
begin
  Operation := TBleGattOperationAccess(Sender);
  for I := FOperations.Count - 1 downto 0 do
  begin
    Entry := TBleGattOperationEntry(FOperations[I]);
    if Entry.Instance <> Sender then Continue;
    FOperations.Delete(I);
    Entry.Free;
    Break;
  end;
  if (Operation.OperationKind = lbckUnsubscribe) and
    (Operation.State in [lbopFailed, lbopCancelled]) and
    (Operation.OperationGeneration = Generation) and (State = lbssConnected) then
  begin
    Disconnect;
    FLastOperationFailed := True;
    FErrorCode := Operation.ErrorCode;
    FErrorMessage := Operation.ErrorMessage;
  end;
end;

function TBleGattSession.ReadAsync(
  const AServiceUuid, ACharacteristicUuid: string): IBleGattOperation;
var
  Command: TLazBleBackendCommand;
begin
  LazBleRequireMainThread;
  Command := Default(TLazBleBackendCommand);
  Command.Kind := lbckRead;
  Command.Generation := Generation;
  Command.DeviceId := FDeviceId;
  Command.ServiceUuid := AServiceUuid;
  Command.CharacteristicUuid := ACharacteristicUuid;
  Result := SubmitGattCommand(Command);
end;

function TBleGattSession.WriteAsync(
  const AServiceUuid, ACharacteristicUuid: string; const AValue: TBytes;
  const AWriteMode: TLazBleWriteMode): IBleGattOperation;
var
  Command: TLazBleBackendCommand;
begin
  LazBleRequireMainThread;
  Command := Default(TLazBleBackendCommand);
  Command.Kind := lbckWrite;
  Command.Generation := Generation;
  Command.DeviceId := FDeviceId;
  Command.ServiceUuid := AServiceUuid;
  Command.CharacteristicUuid := ACharacteristicUuid;
  Command.Value := AValue; { backend copies the buffer at Submit }
  Command.WriteMode := AWriteMode;
  Result := SubmitGattCommand(Command);
end;

function TBleGattSession.DescriptorCommand(const AKind: TLazBleBackendCommandKind;
  const AServiceUuid, ACharacteristicUuid, ADescriptorUuid: string;
  const AValue: TBytes): IBleGattOperation;
var
  Command: TLazBleBackendCommand;
  Characteristic: TLazBleGattCharacteristic;
  Descriptor: TLazBleGattDescriptor;
  Found: Boolean;
begin
  LazBleRequireMainThread;
  if (State <> lbssConnected) or FShuttingDown then
    Exit(TBleGattOperationAccess.CreateFailed(AKind, LazBleErrorInvalidState,
      'Descriptor operation requires a connected session'));
  Found := False;
  if TryGetCharacteristic(AServiceUuid, ACharacteristicUuid, Characteristic) then
    for Descriptor in Characteristic.Descriptors do
      if SameText(UTF8Encode(Descriptor), ADescriptorUuid) then
      begin
        Found := True;
        Break;
      end;
  if not Found then
    Exit(TBleGattOperationAccess.CreateFailed(AKind, LazBleErrorGattNotFound,
      'GATT descriptor not found'));
  Command := Default(TLazBleBackendCommand);
  Command.Kind := AKind;
  Command.Generation := Generation;
  Command.DeviceId := FDeviceId;
  Command.ServiceUuid := AServiceUuid;
  Command.CharacteristicUuid := ACharacteristicUuid;
  Command.DescriptorUuid := ADescriptorUuid;
  Command.Value := AValue;
  Result := SubmitGattCommand(Command);
end;

function TBleGattSession.ReadDescriptorAsync(const AServiceUuid, ACharacteristicUuid,
  ADescriptorUuid: string): IBleGattOperation;
begin
  Result := DescriptorCommand(lbckReadDescriptor, AServiceUuid,
    ACharacteristicUuid, ADescriptorUuid, nil);
end;

function TBleGattSession.WriteDescriptorAsync(const AServiceUuid, ACharacteristicUuid,
  ADescriptorUuid: string; const AValue: TBytes): IBleGattOperation;
begin
  Result := DescriptorCommand(lbckWriteDescriptor, AServiceUuid,
    ACharacteristicUuid, ADescriptorUuid, AValue);
end;

function TBleGattSession.SubscribeAsync(
  const AServiceUuid, ACharacteristicUuid: string;
  const AMode: TLazBleSubscriptionMode): IBleSubscription;
var
  Command: TLazBleBackendCommand;
  Entry: TBleSubscriptionEntry;
  OperationId: TBleOperationId;
  Subscription: TBleSubscriptionAccess;
  Characteristic: TLazBleGattCharacteristic;
begin
  LazBleRequireMainThread;
  if (State <> lbssConnected) or FShuttingDown then
    Exit(TBleSubscriptionAccess.CreateFailed(LazBleErrorInvalidState,
      'Subscription requires a connected session'));
  if not TryGetCharacteristic(AServiceUuid, ACharacteristicUuid, Characteristic) then
    Exit(TBleSubscriptionAccess.CreateFailed(LazBleErrorGattNotFound,
      'GATT characteristic not found'));
  if ((AMode = lbsmNotify) and not Characteristic.CanNotify) or
    ((AMode = lbsmIndicate) and not Characteristic.CanIndicate) then
    Exit(TBleSubscriptionAccess.CreateFailed(LazBleErrorGattPropertyNotSupported,
      'GATT characteristic does not support the subscription mode'));
  Command := Default(TLazBleBackendCommand);
  Command.Kind := lbckSubscribe;
  Command.Generation := Generation;
  Command.DeviceId := FDeviceId;
  Command.ServiceUuid := AServiceUuid;
  Command.CharacteristicUuid := ACharacteristicUuid;
  Command.SubscriptionMode := AMode;
  Subscription := TBleSubscriptionAccess.CreateRequestInternal(Generation,
    @UnsubscribeSubscription, @SubscriptionRetired);
  Result := Subscription;
  Entry := TBleSubscriptionEntry.Create;
  Entry.Instance := Subscription;
  Entry.Subscription := Result;
  FSubscriptions.Add(Entry);
  OperationId := FSubmitCommand(Command, Subscription, Subscription);
  Subscription.Bind(OperationId);
end;

procedure TBleGattSession.SubscriptionRetired(Sender: TObject);
var I: Integer; Entry: TBleSubscriptionEntry;
begin
  for I := FSubscriptions.Count - 1 downto 0 do
  begin
    Entry := TBleSubscriptionEntry(FSubscriptions[I]);
    if Entry.Instance <> Sender then Continue;
    TBleSubscriptionAccess(Entry.Instance).DetachFromSession;
    FSubscriptions.Delete(I);
    Entry.Free;
    Exit;
  end;
end;

function TBleGattSession.UnsubscribeSubscription(
  const ASubscription: TBleSubscription): IBleGattOperation;
var
  Command: TLazBleBackendCommand;
begin
  LazBleRequireMainThread;
  if TBleSubscriptionAccess(ASubscription).SubscriptionId = InvalidBleSubscriptionId then
  begin
    if Assigned(FCancelOperation) then
      FCancelOperation(TBleSubscriptionAccess(ASubscription).OperationId);
    Exit(nil); { Wait for the actual Notify outcome; the token chains cleanup. }
  end;
  Command := Default(TLazBleBackendCommand);
  Command.Kind := lbckUnsubscribe;
  Command.Generation := Generation;
  Command.DeviceId := FDeviceId;
  Command.SubscriptionId :=
    TBleSubscriptionAccess(ASubscription).SubscriptionId;
  Result := SubmitGattCommand(Command);
end;

procedure TBleGattSession.InvalidateGattState(const AForce: Boolean);
var
  OpEntry: TBleGattOperationEntry;
  SubEntry: TBleSubscriptionEntry;
  Operations: TBleGattOperationInterfaces;
  Instances: TBleGattOperationObjects;
  Subscriptions: TBleSubscriptionInterfaces;
  Tokens: TBleSubscriptionObjects;
  I, J: Integer;
begin
  LazBleRequireMainThread;
  FServices := nil;
  SetLength(Operations,FOperations.Count); SetLength(Instances,FOperations.Count);
  for I := 0 to FOperations.Count - 1 do
  begin
    OpEntry := TBleGattOperationEntry(FOperations[I]);
    Operations[I] := OpEntry.Operation; Instances[I] := OpEntry.Instance;
  end;
  for I := 0 to High(Operations) do
    if AForce then
    begin
      TBleGattOperationAccess(Instances[I]).DetachFromSession;
      TBleGattOperationAccess(Instances[I]).CancelWithoutBackend;
      for J := FOperations.Count - 1 downto 0 do
      begin
        OpEntry := TBleGattOperationEntry(FOperations[J]);
        if OpEntry.Instance <> Instances[I] then Continue;
        FOperations.Delete(J); OpEntry.Free; Break;
      end;
    end
    else Operations[I].Cancel; { queued calls skip, in-flight calls retain real outcomes }
  SetLength(Subscriptions,FSubscriptions.Count); SetLength(Tokens,FSubscriptions.Count);
  for I := 0 to FSubscriptions.Count - 1 do
  begin
    SubEntry := TBleSubscriptionEntry(FSubscriptions[I]);
    Subscriptions[I] := SubEntry.Subscription; Tokens[I] := SubEntry.Instance;
  end;
  for I := 0 to High(Tokens) do
  begin
    TBleSubscriptionAccess(Tokens[I]).InvalidateInternal(AForce);
    if TBleSubscriptionAccess(Tokens[I]).CleanupPendingInternal then Continue;
    for J := FSubscriptions.Count - 1 downto 0 do
    begin
      SubEntry := TBleSubscriptionEntry(FSubscriptions[J]);
      if SubEntry.Instance <> Tokens[I] then Continue;
      FSubscriptions.Delete(J); SubEntry.Free; Break;
    end;
  end;
end;

function TBleGattSession.BeginConnect: IBleOperation;
var Workflow: TSessionWorkflow;
begin
  LazBleRequireMainThread;
  if (FConnectWorkflow <> nil) and (FConnectWorkflow.State = lbopPending) then
    Exit(FConnectWorkflow);
  if State in [lbssDisconnected, lbssError] then Inc(FGeneration);
  Workflow := TSessionWorkflow.Create(Self, lbckConnect);
  Result := Workflow;
  FConnectWorkflow := Result;
  FConnectWorkflowObject := Workflow;
  if State = lbssConnected then
    Workflow.Complete(lbopSucceeded)
  else if not (State in [lbssDisconnected, lbssError]) or FShuttingDown then
    Workflow.Complete(lbopFailed, LazBleErrorInvalidState, 'Could not start BLE connection')
  else
  begin
    FServices := nil;
    FErrorCode := 0; FErrorMessage := '';
    FLastOperationFailed := False; FLastOperationCancelled := False;
    FConnectionEstablished := False;
    Workflow.Start(lbckConnect);
    FConnectOperationId := Workflow.FId;
    if Workflow.State = lbopPending then SetState(lbssConnecting);
  end;
end;

function TBleGattSession.BeginDisconnect: IBleOperation;
var Workflow: TSessionWorkflow;
begin
  LazBleRequireMainThread;
  if (FDisconnectWorkflow <> nil) and (FDisconnectWorkflow.State = lbopPending) then
    Exit(FDisconnectWorkflow);
  Workflow := TSessionWorkflow.Create(Self, lbckDisconnect);
  Result := Workflow;
  FDisconnectWorkflow := Result;
  FDisconnectWorkflowObject := Workflow;
  if State = lbssDisconnected then
    Workflow.Complete(lbopSucceeded)
  else if (State = lbssDisconnecting) or FShuttingDown then
    Workflow.Complete(lbopFailed, LazBleErrorInvalidState, 'Could not start BLE disconnect')
  else
  begin
    FErrorCode := 0; FErrorMessage := '';
    FLastOperationFailed := False; FLastOperationCancelled := False;
    Workflow.Start(lbckDisconnect);
    FDisconnectOperationId := Workflow.FId;
    if Workflow.State = lbopPending then SetState(lbssDisconnecting);
  end;
end;

function TBleGattSession.Connect: TBleOperationId;
var Operation: IBleOperation;
begin
  if not (State in [lbssDisconnected, lbssError]) then Exit(InvalidBleOperationId);
  Operation := BeginConnect;
  Result := FConnectOperationId;
end;

function TBleGattSession.Disconnect: TBleOperationId;
var Operation: IBleOperation;
begin
  if not (State in [lbssConnecting, lbssDiscovering, lbssConnected, lbssError]) then
    Exit(InvalidBleOperationId);
  Operation := BeginDisconnect;
  Result := FDisconnectOperationId;
end;

procedure TBleGattSession.CancelConnect;
begin
  LazBleRequireMainThread;
  if not Assigned(FCancelOperation) then Exit;
  if State = lbssConnecting then FCancelOperation(FConnectOperationId)
  else if State = lbssDiscovering then FCancelOperation(FDiscoveryOperationId);
end;

procedure TBleGattSession.CancelDisconnect;
begin
  LazBleRequireMainThread;
  if (State = lbssDisconnecting) and Assigned(FCancelOperation) then
    FCancelOperation(FDisconnectOperationId);
end;

procedure TBleGattSession.HandleLinkChanged(const AConnected: Boolean; const AGeneration: QWord);
begin
  LazBleRequireMainThread;
  if FShuttingDown or ((AGeneration <> 0) and (AGeneration <> Generation)) then Exit;
  if AConnected then FConnectionEstablished := True
  else if State <> lbssDisconnected then
  begin
    FConnectionEstablished := False;
    InvalidateGattState;
    SetState(lbssDisconnected);
  end;
end;

procedure TBleGattSession.PrepareShutdown;
var I: Integer;
begin
  LazBleRequireMainThread;
  FShuttingDown := True;
  for I := 0 to FSubscriptions.Count - 1 do
    TBleSubscriptionAccess(TBleSubscriptionEntry(FSubscriptions[I]).Instance).BeginShutdownInternal;
end;

procedure TBleGattSession.HandleBackendShutdown;
var R: TLazBleRequestResult;
begin
  LazBleRequireMainThread;
  FConnectionEstablished := False;
  InvalidateGattState(True);
  R := Default(TLazBleRequestResult); R.Status := lbrsCancelled;
  if FConnectWorkflow <> nil then TSessionWorkflow(FConnectWorkflowObject).CompleteRequest(R);
  if FDisconnectWorkflow <> nil then TSessionWorkflow(FDisconnectWorkflowObject).CompleteRequest(R);
  FSubmitCommand := nil;
  FCancelOperation := nil;
  SetState(lbssDisconnected);
end;

end.
