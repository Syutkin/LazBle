unit LazBleClient;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  LazBleTypes,
  LazBleOperation,
  LazBleGattOperation,
  LazBleGattSubscription,
  LazBleGattSession,
  LazBleGattProfile,
  LazBleClientInternal,
  LazBleReconnect;

type
  TLazBleClientState = (
    lbcstDisconnected,
    lbcstConnecting,
    lbcstAttachingProfiles,
    lbcstReady,
    lbcstWaitingToReconnect,
    lbcstDisconnecting,
    lbcstError
  );

  TLazBleClientStateChangedEvent = procedure(Sender: TObject;
    const AState: TLazBleClientState) of object;

  TBleClient = class
  private
    FConnectSession: TLazBleConnectSessionEvent;
    FDisconnectSession: TLazBleDisconnectSessionEvent;
    FSession: TBleGattSession;
    FProfiles: TList;
    FStateLock: TRTLCriticalSection;
    FCallbackLock: TRTLCriticalSection;
    FState: TLazBleClientState;
    FAttachingProfiles: Boolean;
    FEvaluatingProfiles: Boolean;
    FConnectOperation: IBleOperation;
    FConnectOperationObject: TBleOperation;
    FDisconnectOperation: IBleOperation;
    FDisconnectOperationObject: TBleOperation;
    FSessionConnectOperation: IBleOperation;
    FSessionDisconnectOperation: IBleOperation;
    FReconnectController: TLazBleReconnectController;
    FReconnectCycleActive: Boolean;
    FManualDisconnect: Boolean;
    FShuttingDown: Boolean;
    FOnStateChanged: TLazBleClientStateChangedEvent;
    function GetDeviceId: string;
    function GetGeneration: QWord;
    function GetServices: TLazBleGattServices;
    function GetProfileCount: Integer;
    function GetProfile(const AIndex: Integer): TBleGattProfile;
    function GetState: TLazBleClientState;
    function GetOnStateChanged: TLazBleClientStateChangedEvent;
    procedure SetOnStateChanged(
      const AHandler: TLazBleClientStateChangedEvent);
    procedure SetState(const AState: TLazBleClientState);
    procedure OperationCancelled(Sender: TObject);
    procedure SessionConnectCompleted(Sender: TObject);
    procedure SessionDisconnectCompleted(Sender: TObject);
    procedure SessionStateChanged(Sender: TObject;
      const AState: TLazBleSessionState);
    procedure ProfileStateChanged(Sender: TObject;
      const AState: TLazBleGattProfileState);
    procedure AttachProfiles;
    procedure DetachProfiles;
    procedure EvaluateProfiles;
    procedure SetAutoReconnect(const AValue: Boolean);
    function GetAutoReconnect: Boolean;
    function GetReconnectOptions: TLazBleReconnectOptions;
    procedure SetReconnectOptions(const AValue: TLazBleReconnectOptions);
    function GetReconnectAttempt: Cardinal;
    function GetReconnectDelayMs: Cardinal;
    procedure ScheduleReconnect;
    procedure ReconnectDelayElapsed;
    procedure DisconnectForReconnect;
    function StartConnect(const AManual: Boolean): IBleOperation;
  protected
    procedure CancelForShutdown;
    { Applications obtain clients from TLazBle.CreateClient. }
    constructor Create(const ASession: TBleGattSession;
      const AConnectSession: TLazBleConnectSessionEvent;
      const ADisconnectSession: TLazBleDisconnectSessionEvent;
      const AReconnectTimer: ILazBleReconnectTimer);
    property Generation: QWord read GetGeneration;
    property Profiles[const AIndex: Integer]: TBleGattProfile read GetProfile;
    property ProfileCount: Integer read GetProfileCount;
  public
    destructor Destroy; override;
    procedure AddProfile(const AProfile: TBleGattProfile;
      const ARequired: Boolean = True);
    function ConnectAsync: IBleOperation;
    function DisconnectAsync: IBleOperation;
    function ReadAsync(const AServiceUuid, ACharacteristicUuid: string):
      IBleGattOperation;
    function WriteAsync(const AServiceUuid, ACharacteristicUuid: string;
      const AValue: TBytes; const AWriteMode: TLazBleWriteMode):
      IBleGattOperation;
    function SubscribeAsync(const AServiceUuid,
      ACharacteristicUuid: string): IBleSubscription;
    property DeviceId: string read GetDeviceId;
    property Services: TLazBleGattServices read GetServices;
    property State: TLazBleClientState read GetState;
    property AutoReconnect: Boolean read GetAutoReconnect
      write SetAutoReconnect;
    property ReconnectOptions: TLazBleReconnectOptions
      read GetReconnectOptions write SetReconnectOptions;
    property ReconnectAttempt: Cardinal read GetReconnectAttempt;
    property ReconnectDelayMs: Cardinal read GetReconnectDelayMs;
    property OnStateChanged: TLazBleClientStateChangedEvent
      read GetOnStateChanged write SetOnStateChanged;
  end;

implementation

type
  TBleOperationAccess = class(TBleOperation)
  public
    constructor CreateInternal(
      const AOnCancel: TLazBleOperationCancelEvent);
    procedure Finish(const AState: TLazBleOperationState;
      const AErrorCode: Integer = 0; const AErrorMessage: string = '');
  end;

  TBleGattProfileAccess = class(TBleGattProfile)
  public
    function IsBound: Boolean;
    procedure AttachInternal;
    procedure DetachInternal;
    procedure AddHandler(
      const AHandler: TLazBleGattProfileStateChangedEvent);
    procedure RemoveHandler(
      const AHandler: TLazBleGattProfileStateChangedEvent);
  end;

  TBleGattSessionAccess = class(TBleGattSession)
  public
    procedure AddHandler(const AHandler: TLazBleSessionStateChangedEvent);
    procedure RemoveHandler(const AHandler: TLazBleSessionStateChangedEvent);
  end;

  TBleClientProfileEntry = class
  public
    Profile: TBleGattProfile;
    Required: Boolean;
  end;

constructor TBleOperationAccess.CreateInternal(
  const AOnCancel: TLazBleOperationCancelEvent);
begin
  inherited Create(AOnCancel);
end;

procedure TBleOperationAccess.Finish(const AState: TLazBleOperationState;
  const AErrorCode: Integer; const AErrorMessage: string);
begin
  Complete(AState, AErrorCode, AErrorMessage);
end;

function TBleGattProfileAccess.IsBound: Boolean;
begin
  Result := Bound;
end;

procedure TBleGattProfileAccess.AttachInternal;
begin
  Attach;
end;

procedure TBleGattProfileAccess.DetachInternal;
begin
  Detach;
end;

procedure TBleGattProfileAccess.AddHandler(
  const AHandler: TLazBleGattProfileStateChangedEvent);
begin
  AddStateChangedHandler(AHandler);
end;

procedure TBleGattProfileAccess.RemoveHandler(
  const AHandler: TLazBleGattProfileStateChangedEvent);
begin
  RemoveStateChangedHandler(AHandler);
end;

procedure TBleGattSessionAccess.AddHandler(
  const AHandler: TLazBleSessionStateChangedEvent);
begin
  AddStateChangedHandler(AHandler);
end;

procedure TBleGattSessionAccess.RemoveHandler(
  const AHandler: TLazBleSessionStateChangedEvent);
begin
  RemoveStateChangedHandler(AHandler);
end;

constructor TBleClient.Create(const ASession: TBleGattSession;
  const AConnectSession: TLazBleConnectSessionEvent;
  const ADisconnectSession: TLazBleDisconnectSessionEvent;
  const AReconnectTimer: ILazBleReconnectTimer);
begin
  inherited Create;
  if not Assigned(ASession) then
    raise EArgumentNilException.Create('ASession');
  if not Assigned(AConnectSession) then
    raise EArgumentNilException.Create('AConnectSession');
  if not Assigned(ADisconnectSession) then
    raise EArgumentNilException.Create('ADisconnectSession');
  if not Assigned(AReconnectTimer) then
    raise EArgumentNilException.Create('AReconnectTimer');
  InitCriticalSection(FStateLock);
  InitCriticalSection(FCallbackLock);
  FConnectSession := AConnectSession;
  FDisconnectSession := ADisconnectSession;
  FSession := ASession;
  FProfiles := TList.Create;
  FReconnectController := TLazBleReconnectController.Create(
    AReconnectTimer);
  FReconnectController.OnElapsed := @ReconnectDelayElapsed;
  FState := lbcstDisconnected;
  TBleGattSessionAccess(FSession).AddHandler(@SessionStateChanged);
end;

destructor TBleClient.Destroy;
var
  Entry: TBleClientProfileEntry;
  Index: Integer;
begin
  SetOnStateChanged(nil);
  FShuttingDown := True;
  FReconnectCycleActive := False;
  FReconnectController.OnElapsed := nil;
  FReconnectController.Disable;
  if Assigned(FSessionConnectOperation) then
    FSessionConnectOperation.OnCompleted := nil;
  if Assigned(FSessionDisconnectOperation) then
    FSessionDisconnectOperation.OnCompleted := nil;
  FConnectOperation := nil;
  FConnectOperationObject := nil;
  FDisconnectOperation := nil;
  FDisconnectOperationObject := nil;
  FSessionConnectOperation := nil;
  FSessionDisconnectOperation := nil;
  if Assigned(FSession) then
    TBleGattSessionAccess(FSession).RemoveHandler(@SessionStateChanged);
  for Index := FProfiles.Count - 1 downto 0 do
  begin
    Entry := TBleClientProfileEntry(FProfiles[Index]);
    TBleGattProfileAccess(Entry.Profile).RemoveHandler(@ProfileStateChanged);
    TBleGattProfileAccess(Entry.Profile).DetachInternal;
    Entry.Profile.Free;
    Entry.Free;
  end;
  FProfiles.Free;
  FReconnectController.Free;
  FSession := nil;
  FConnectSession := nil;
  FDisconnectSession := nil;
  DoneCriticalSection(FCallbackLock);
  DoneCriticalSection(FStateLock);
  inherited Destroy;
end;

function TBleClient.GetState: TLazBleClientState;
begin
  EnterCriticalSection(FStateLock);
  try
    Result := FState;
  finally
    LeaveCriticalSection(FStateLock);
  end;
end;

function TBleClient.GetOnStateChanged: TLazBleClientStateChangedEvent;
begin
  EnterCriticalSection(FCallbackLock);
  try
    Result := FOnStateChanged;
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
end;

procedure TBleClient.SetOnStateChanged(
  const AHandler: TLazBleClientStateChangedEvent);
begin
  EnterCriticalSection(FCallbackLock);
  try
    FOnStateChanged := AHandler;
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
end;

function TBleClient.GetAutoReconnect: Boolean;
begin
  Result := FReconnectController.Enabled;
end;

procedure TBleClient.SetAutoReconnect(const AValue: Boolean);
begin
  if AValue then
    FReconnectController.Enable
  else
  begin
    FReconnectCycleActive := False;
    FReconnectController.Disable;
    if State = lbcstWaitingToReconnect then
      SetState(lbcstDisconnected);
  end;
end;

function TBleClient.GetReconnectOptions: TLazBleReconnectOptions;
begin
  Result := FReconnectController.Options;
end;

procedure TBleClient.SetReconnectOptions(
  const AValue: TLazBleReconnectOptions);
begin
  if FReconnectCycleActive then
    raise EInvalidOperation.Create(
      'Reconnect options cannot be changed during a reconnect cycle');
  FReconnectController.SetOptions(AValue);
end;

function TBleClient.GetReconnectAttempt: Cardinal;
begin
  Result := FReconnectController.Attempt;
end;

function TBleClient.GetReconnectDelayMs: Cardinal;
begin
  Result := FReconnectController.DelayMs;
end;

function TBleClient.GetDeviceId: string;
begin
  if Assigned(FSession) then
    Result := FSession.DeviceId
  else
    Result := '';
end;

function TBleClient.GetGeneration: QWord;
begin
  if Assigned(FSession) then
    Result := FSession.Generation
  else
    Result := 0;
end;

function TBleClient.GetServices: TLazBleGattServices;
begin
  if Assigned(FSession) then
    Result := FSession.Services
  else
    Result := nil;
end;

function TBleClient.GetProfileCount: Integer;
begin
  Result := FProfiles.Count;
end;

function TBleClient.GetProfile(const AIndex: Integer): TBleGattProfile;
begin
  Result := TBleClientProfileEntry(FProfiles[AIndex]).Profile;
end;

procedure TBleClient.SetState(const AState: TLazBleClientState);
var
  Handler: TLazBleClientStateChangedEvent;
begin
  EnterCriticalSection(FStateLock);
  try
    if FState = AState then
      Exit;
    FState := AState;
  finally
    LeaveCriticalSection(FStateLock);
  end;
  EnterCriticalSection(FCallbackLock);
  try
    Handler := FOnStateChanged;
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
  if Assigned(Handler) then
    Handler(Self, AState);
end;

procedure TBleClient.AddProfile(const AProfile: TBleGattProfile;
  const ARequired: Boolean);
var
  Entry: TBleClientProfileEntry;
  Index: Integer;
begin
  if not Assigned(AProfile) then
    raise EArgumentNilException.Create('AProfile');
  if State <> lbcstDisconnected then
    raise EInvalidOperation.Create(
      'Profiles can only be added while disconnected');
  if TBleGattProfileAccess(AProfile).IsBound then
    raise EInvalidOperation.Create('Profile is already bound to a client');
  for Index := 0 to FProfiles.Count - 1 do
    if TBleClientProfileEntry(FProfiles[Index]).Profile = AProfile then
      raise EInvalidOperation.Create('Profile is already registered');
  Entry := TBleClientProfileEntry.Create;
  try
    TBleGattProfileAccess(AProfile).BindSession(FSession);
    Entry.Profile := AProfile;
    Entry.Required := ARequired;
    TBleGattProfileAccess(AProfile).AddHandler(@ProfileStateChanged);
    FProfiles.Add(Entry);
  except
    Entry.Free;
    raise;
  end;
end;

procedure TBleClient.AttachProfiles;
var
  Index: Integer;
begin
  SetState(lbcstAttachingProfiles);
  FAttachingProfiles := True;
  try
    for Index := 0 to FProfiles.Count - 1 do
      TBleGattProfileAccess(
        TBleClientProfileEntry(FProfiles[Index]).Profile).AttachInternal;
  finally
    FAttachingProfiles := False;
  end;
  EvaluateProfiles;
end;

procedure TBleClient.DetachProfiles;
var
  Index: Integer;
begin
  for Index := FProfiles.Count - 1 downto 0 do
    TBleGattProfileAccess(
      TBleClientProfileEntry(FProfiles[Index]).Profile).DetachInternal;
end;

procedure TBleClient.EvaluateProfiles;
var
  AllRequiredReady: Boolean;
  Entry: TBleClientProfileEntry;
  Index: Integer;
  ReconnectAfterProfileFailure: Boolean;
begin
  if FAttachingProfiles or FEvaluatingProfiles or
    not (State in [lbcstAttachingProfiles, lbcstReady]) then
    Exit;
  FEvaluatingProfiles := True;
  try
    AllRequiredReady := True;
    for Index := 0 to FProfiles.Count - 1 do
    begin
      Entry := TBleClientProfileEntry(FProfiles[Index]);
      if not Entry.Required then
        Continue;
      case Entry.Profile.State of
        lbgpsError:
          begin
            ReconnectAfterProfileFailure := FReconnectCycleActive or
              ((State = lbcstReady) and FReconnectController.Enabled and
              not FManualDisconnect and not FShuttingDown);
            SetState(lbcstError);
            if Assigned(FConnectOperation) then
              TBleOperationAccess(FConnectOperationObject).Finish(
                lbopFailed, Entry.Profile.ErrorCode,
                Entry.Profile.ClassName + ': ' +
                Entry.Profile.ErrorMessage);
            if ReconnectAfterProfileFailure then
            begin
              FReconnectCycleActive := True;
              DisconnectForReconnect
            end
            else
            begin
              DetachProfiles;
              FSessionDisconnectOperation := FDisconnectSession(FSession);
              SetState(lbcstDisconnecting);
              FSessionDisconnectOperation.OnCompleted :=
                @SessionDisconnectCompleted;
            end;
            Exit;
          end;
        lbgpsReady:
          ;
        else
          AllRequiredReady := False;
      end;
    end;
    if AllRequiredReady and (State = lbcstAttachingProfiles) then
    begin
      FReconnectCycleActive := False;
      FReconnectController.Reset;
      SetState(lbcstReady);
      if Assigned(FConnectOperation) then
        TBleOperationAccess(FConnectOperationObject).Finish(lbopSucceeded);
    end;
  finally
    FEvaluatingProfiles := False;
  end;
end;

procedure TBleClient.ProfileStateChanged(Sender: TObject;
  const AState: TLazBleGattProfileState);
begin
  EvaluateProfiles;
end;

procedure TBleClient.SessionConnectCompleted(Sender: TObject);
var
  Operation: IBleOperation;
begin
  if not Supports(Sender, IBleOperation, Operation) then
    Exit;
  if Operation.State = lbopSucceeded then
    AttachProfiles
  else
  begin
    SetState(lbcstError);
    if Assigned(FConnectOperation) then
      if Operation.State = lbopCancelled then
        TBleOperationAccess(FConnectOperationObject).Finish(lbopCancelled)
      else
        TBleOperationAccess(FConnectOperationObject).Finish(lbopFailed,
          Operation.ErrorCode, Operation.ErrorMessage);
    if FReconnectCycleActive then
      ScheduleReconnect;
  end;
end;

procedure TBleClient.SessionDisconnectCompleted(Sender: TObject);
var
  Operation: IBleOperation;
begin
  if not Supports(Sender, IBleOperation, Operation) then
    Exit;
  if Operation.State = lbopSucceeded then
  begin
    SetState(lbcstDisconnected);
    if Assigned(FDisconnectOperation) then
      TBleOperationAccess(FDisconnectOperationObject).Finish(lbopSucceeded);
  end
  else
  begin
    SetState(lbcstError);
    if Assigned(FDisconnectOperation) then
      TBleOperationAccess(FDisconnectOperationObject).Finish(lbopFailed,
        Operation.ErrorCode, Operation.ErrorMessage);
    if FReconnectCycleActive then
      ScheduleReconnect;
  end;
end;

procedure TBleClient.SessionStateChanged(Sender: TObject;
  const AState: TLazBleSessionState);
var
  ShouldReconnect: Boolean;
begin
  if Sender <> FSession then
    Exit;
  if AState = lbssDisconnected then
  begin
    ShouldReconnect := not FManualDisconnect and not FShuttingDown and
      (FReconnectCycleActive or FReconnectController.Waiting or
      (State = lbcstReady) or
      ((State = lbcstError) and
      (FReconnectController.Attempt > 0)));
    DetachProfiles;
    SetState(lbcstDisconnected);
    if Assigned(FConnectOperation) and
      (FConnectOperation.State = lbopPending) then
      if FConnectOperation.CancelRequested then
        TBleOperationAccess(FConnectOperationObject).Finish(lbopCancelled)
      else
        TBleOperationAccess(FConnectOperationObject).Finish(lbopFailed, 0,
          'BLE connection was closed');
    if ShouldReconnect then
    begin
      FReconnectCycleActive := True;
      ScheduleReconnect;
    end;
  end;
end;

procedure TBleClient.ScheduleReconnect;
begin
  if FManualDisconnect or FShuttingDown or
    not FReconnectController.Enabled then
  begin
    FReconnectCycleActive := False;
    Exit;
  end;
  if FReconnectController.Waiting then
  begin
    SetState(lbcstWaitingToReconnect);
    Exit;
  end;
  if FReconnectController.Schedule then
    SetState(lbcstWaitingToReconnect)
  else
  begin
    FReconnectCycleActive := False;
    SetState(lbcstError);
  end;
end;

procedure TBleClient.ReconnectDelayElapsed;
begin
  if not FReconnectCycleActive or FManualDisconnect or FShuttingDown then
    Exit;
  StartConnect(False);
end;

procedure TBleClient.DisconnectForReconnect;
begin
  DetachProfiles;
  FSessionDisconnectOperation := FDisconnectSession(FSession);
  FSessionDisconnectOperation.OnCompleted := @SessionDisconnectCompleted;
end;

procedure TBleClient.OperationCancelled(Sender: TObject);
begin
  if Sender = FConnectOperationObject then
  begin
    if Assigned(FSessionConnectOperation) and
      (FSessionConnectOperation.State = lbopPending) then
      FSessionConnectOperation.Cancel
    else
    begin
      DetachProfiles;
      FDisconnectSession(FSession);
      TBleOperationAccess(FConnectOperationObject).Finish(lbopCancelled);
    end;
  end
  else if Sender = FDisconnectOperationObject then
    TBleOperationAccess(FDisconnectOperationObject).Finish(lbopCancelled);
end;

procedure TBleClient.CancelForShutdown;
begin
  FShuttingDown := True;
  FManualDisconnect := True;
  FReconnectCycleActive := False;
  FReconnectController.Disable;
  if State = lbcstWaitingToReconnect then
    SetState(lbcstDisconnected);
  if Assigned(FConnectOperation) and
    (FConnectOperation.State = lbopPending) then
    FConnectOperation.Cancel;
  if Assigned(FDisconnectOperation) and
    (FDisconnectOperation.State = lbopPending) then
    FDisconnectOperation.Cancel;
end;

function TBleClient.ConnectAsync: IBleOperation;
begin
  Result := StartConnect(True);
end;

function TBleClient.StartConnect(const AManual: Boolean): IBleOperation;
var
  Operation: TBleOperationAccess;
begin
  if Assigned(FConnectOperation) and
    (FConnectOperation.State = lbopPending) then
    Exit(FConnectOperation);
  if AManual then
  begin
    FManualDisconnect := False;
    FReconnectCycleActive := False;
    FReconnectController.Reset;
    if State = lbcstWaitingToReconnect then
      SetState(lbcstDisconnected);
  end;
  if not AManual and (State = lbcstWaitingToReconnect) then
    SetState(lbcstDisconnected);
  if Assigned(FConnectOperation) then
    FConnectOperation.OnCompleted := nil;
  FConnectOperation := nil;
  FConnectOperationObject := nil;
  Operation := TBleOperationAccess.CreateInternal(@OperationCancelled);
  Result := Operation;
  FConnectOperation := Result;
  FConnectOperationObject := Operation;
  if State = lbcstReady then
  begin
    Operation.Finish(lbopSucceeded);
    Exit;
  end;
  if State <> lbcstDisconnected then
  begin
    Operation.Finish(lbopFailed, 0,
      'BLE connection must be disconnected before connecting');
    Exit;
  end;
  SetState(lbcstConnecting);
  FSessionConnectOperation := FConnectSession(DeviceId);
  FSessionConnectOperation.OnCompleted := @SessionConnectCompleted;
end;

function TBleClient.DisconnectAsync: IBleOperation;
var
  Operation: TBleOperationAccess;
begin
  FManualDisconnect := True;
  FReconnectCycleActive := False;
  FReconnectController.Reset;
  if Assigned(FDisconnectOperation) and
    (FDisconnectOperation.State = lbopPending) then
    Exit(FDisconnectOperation);
  if Assigned(FDisconnectOperation) then
    FDisconnectOperation.OnCompleted := nil;
  FDisconnectOperation := nil;
  FDisconnectOperationObject := nil;
  Operation := TBleOperationAccess.CreateInternal(@OperationCancelled);
  Result := Operation;
  FDisconnectOperation := Result;
  FDisconnectOperationObject := Operation;
  if State in [lbcstDisconnected, lbcstWaitingToReconnect] then
  begin
    SetState(lbcstDisconnected);
    Operation.Finish(lbopSucceeded);
    Exit;
  end;
  SetState(lbcstDisconnecting);
  DetachProfiles;
  FSessionDisconnectOperation := FDisconnectSession(FSession);
  FSessionDisconnectOperation.OnCompleted := @SessionDisconnectCompleted;
end;

function TBleClient.ReadAsync(const AServiceUuid,
  ACharacteristicUuid: string): IBleGattOperation;
begin
  Result := FSession.ReadAsync(AServiceUuid, ACharacteristicUuid);
end;

function TBleClient.WriteAsync(const AServiceUuid,
  ACharacteristicUuid: string; const AValue: TBytes;
  const AWriteMode: TLazBleWriteMode): IBleGattOperation;
begin
  Result := FSession.WriteAsync(AServiceUuid, ACharacteristicUuid, AValue,
    AWriteMode);
end;

function TBleClient.SubscribeAsync(const AServiceUuid,
  ACharacteristicUuid: string): IBleSubscription;
begin
  Result := FSession.SubscribeAsync(AServiceUuid, ACharacteristicUuid);
end;

end.
