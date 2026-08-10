unit LazBleClient;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  LazBleTypes,
  LazBleGattOperation,
  LazBleGattSubscription,
  LazBleGattSession,
  LazBleGattProfile,
  LazBleReconnect;

type
  TLazBleOperationState = (
    lbopPending,
    lbopSucceeded,
    lbopFailed,
    lbopCancelled,
    lbopTimedOut
  );

  TLazBleOperationCompletedEvent = procedure(Sender: TObject) of object;
  TLazBleOperationCancelEvent = procedure(Sender: TObject) of object;

  TBleOperation = class
  private
    FLock: TRTLCriticalSection;
    FCallbackLock: TRTLCriticalSection;
    FState: TLazBleOperationState;
    FErrorCode: Integer;
    FErrorMessage: string;
    FCancelRequested: Boolean;
    FOnCancel: TLazBleOperationCancelEvent;
    FOnCompleted: TLazBleOperationCompletedEvent;
    function GetState: TLazBleOperationState;
    function GetErrorCode: Integer;
    function GetErrorMessage: string;
    function GetCancelRequested: Boolean;
    procedure SetOnCompleted(
      const AHandler: TLazBleOperationCompletedEvent);
  protected
    procedure Complete(const AState: TLazBleOperationState;
      const AErrorCode: Integer = 0; const AErrorMessage: string = '');
  public
    constructor Create(const AOnCancel: TLazBleOperationCancelEvent);
    destructor Destroy; override;
    procedure Cancel;
    procedure Timeout;
    property State: TLazBleOperationState read GetState;
    property ErrorCode: Integer read GetErrorCode;
    property ErrorMessage: string read GetErrorMessage;
    property CancelRequested: Boolean read GetCancelRequested;
    property OnCompleted: TLazBleOperationCompletedEvent
      read FOnCompleted write SetOnCompleted;
  end;

  TBleScanOperation = class(TBleOperation)
  private
    FResultsLock: TRTLCriticalSection;
    FResults: TBleDeviceInfos;
    function GetResults: TBleDeviceInfos;
  protected
    procedure AddOrUpdateResult(const ADeviceId, ADeviceName: string;
      const ARssi: SmallInt);
  public
    constructor Create(const AOnCancel: TLazBleOperationCancelEvent);
    destructor Destroy; override;
    property Results: TBleDeviceInfos read GetResults;
  end;

  TLazBleSessionOperationKind = (
    lbsokConnect,
    lbsokDisconnect
  );

  TBleSessionOperation = class(TBleOperation)
  private
    FKind: TLazBleSessionOperationKind;
    FSession: TBleGattSession;
  public
    constructor Create(const ASession: TBleGattSession;
      const AKind: TLazBleSessionOperationKind;
      const AOnCancel: TLazBleOperationCancelEvent);
    property Kind: TLazBleSessionOperationKind read FKind;
    property Session: TBleGattSession read FSession;
  end;

  TLazBleConnectSessionEvent = function(const ADeviceId: string):
    TBleSessionOperation of object;
  TLazBleDisconnectSessionEvent = function(
    const ASession: TBleGattSession): TBleSessionOperation of object;

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
    FOperations: TList;
    FState: TLazBleClientState;
    FAttachingProfiles: Boolean;
    FEvaluatingProfiles: Boolean;
    FConnectOperation: TBleOperation;
    FDisconnectOperation: TBleOperation;
    FSessionConnectOperation: TBleSessionOperation;
    FSessionDisconnectOperation: TBleSessionOperation;
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
    function StartConnect(const AManual: Boolean): TBleOperation;
  protected
    procedure CancelForShutdown;
  public
    { Applications obtain clients from TLazBle.CreateClient. }
    constructor Create(const ASession: TBleGattSession;
      const AConnectSession: TLazBleConnectSessionEvent;
      const ADisconnectSession: TLazBleDisconnectSessionEvent;
      const AReconnectTimer: ILazBleReconnectTimer);
    destructor Destroy; override;
    procedure AddProfile(const AProfile: TBleGattProfile;
      const ARequired: Boolean = True);
    function ConnectAsync: TBleOperation;
    function DisconnectAsync: TBleOperation;
    function ReadAsync(const AServiceUuid, ACharacteristicUuid: string):
      TBleGattOperation;
    function WriteAsync(const AServiceUuid, ACharacteristicUuid: string;
      const AValue: TBytes; const AWriteMode: TLazBleWriteMode):
      TBleGattOperation;
    function SubscribeAsync(const AServiceUuid,
      ACharacteristicUuid: string): TBleSubscription;
    property DeviceId: string read GetDeviceId;
    property Generation: QWord read GetGeneration;
    property Services: TLazBleGattServices read GetServices;
    property Profiles[const AIndex: Integer]: TBleGattProfile read GetProfile;
    property ProfileCount: Integer read GetProfileCount;
    property State: TLazBleClientState read FState;
    property AutoReconnect: Boolean read GetAutoReconnect
      write SetAutoReconnect;
    property ReconnectOptions: TLazBleReconnectOptions
      read GetReconnectOptions write SetReconnectOptions;
    property ReconnectAttempt: Cardinal read GetReconnectAttempt;
    property ReconnectDelayMs: Cardinal read GetReconnectDelayMs;
    property OnStateChanged: TLazBleClientStateChangedEvent
      read FOnStateChanged write FOnStateChanged;
  end;

implementation

type
  TBleGattProfileAccess = class(TBleGattProfile);

  TBleClientProfileEntry = class
  public
    Profile: TBleGattProfile;
    Required: Boolean;
  end;

constructor TBleOperation.Create(
  const AOnCancel: TLazBleOperationCancelEvent);
begin
  inherited Create;
  InitCriticalSection(FLock);
  InitCriticalSection(FCallbackLock);
  FState := lbopPending;
  FOnCancel := AOnCancel;
end;

destructor TBleOperation.Destroy;
begin
  FOnCancel := nil;
  EnterCriticalSection(FCallbackLock);
  try
    FOnCompleted := nil;
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
  DoneCriticalSection(FCallbackLock);
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function TBleOperation.GetState: TLazBleOperationState;
begin
  EnterCriticalSection(FLock);
  try
    Result := FState;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TBleOperation.GetErrorCode: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Result := FErrorCode;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TBleOperation.GetErrorMessage: string;
begin
  EnterCriticalSection(FLock);
  try
    Result := FErrorMessage;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TBleOperation.GetCancelRequested: Boolean;
begin
  EnterCriticalSection(FLock);
  try
    Result := FCancelRequested;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TBleOperation.SetOnCompleted(
  const AHandler: TLazBleOperationCompletedEvent);
var
  NotifyNow: Boolean;
begin
  EnterCriticalSection(FCallbackLock);
  try
    EnterCriticalSection(FLock);
    try
      FOnCompleted := AHandler;
      NotifyNow := Assigned(AHandler) and (FState <> lbopPending);
    finally
      LeaveCriticalSection(FLock);
    end;
    if NotifyNow then
      AHandler(Self);
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
end;

procedure TBleOperation.Complete(
  const AState: TLazBleOperationState; const AErrorCode: Integer;
  const AErrorMessage: string);
var
  CompletedHandler: TLazBleOperationCompletedEvent;
begin
  EnterCriticalSection(FLock);
  try
    if FState <> lbopPending then
      Exit;
    FState := AState;
    FErrorCode := AErrorCode;
    FErrorMessage := AErrorMessage;
  finally
    LeaveCriticalSection(FLock);
  end;
  EnterCriticalSection(FCallbackLock);
  try
    CompletedHandler := FOnCompleted;
    if Assigned(CompletedHandler) then
      CompletedHandler(Self);
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
end;

procedure TBleOperation.Cancel;
var
  CancelHandler: TLazBleOperationCancelEvent;
begin
  EnterCriticalSection(FLock);
  try
    if (FState <> lbopPending) or FCancelRequested then
      Exit;
    FCancelRequested := True;
    CancelHandler := FOnCancel;
  finally
    LeaveCriticalSection(FLock);
  end;
  if Assigned(CancelHandler) then
    CancelHandler(Self)
  else
    Complete(lbopCancelled);
end;

procedure TBleOperation.Timeout;
var
  CancelHandler: TLazBleOperationCancelEvent;
  CompletedHandler: TLazBleOperationCompletedEvent;
begin
  EnterCriticalSection(FLock);
  try
    if FState <> lbopPending then
      Exit;
    FCancelRequested := True;
    FState := lbopTimedOut;
    FErrorCode := 0;
    FErrorMessage := 'BLE operation timed out';
    CancelHandler := FOnCancel;
  finally
    LeaveCriticalSection(FLock);
  end;
  if Assigned(CancelHandler) then
    CancelHandler(Self);
  EnterCriticalSection(FCallbackLock);
  try
    CompletedHandler := FOnCompleted;
    if Assigned(CompletedHandler) then
      CompletedHandler(Self);
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
end;

constructor TBleScanOperation.Create(
  const AOnCancel: TLazBleOperationCancelEvent);
begin
  inherited Create(AOnCancel);
  InitCriticalSection(FResultsLock);
end;

destructor TBleScanOperation.Destroy;
begin
  DoneCriticalSection(FResultsLock);
  inherited Destroy;
end;

procedure TBleScanOperation.AddOrUpdateResult(const ADeviceId,
  ADeviceName: string; const ARssi: SmallInt);
var
  Index: Integer;
begin
  EnterCriticalSection(FResultsLock);
  try
    for Index := 0 to High(FResults) do
      if SameText(FResults[Index].DeviceId, ADeviceId) then
      begin
        FResults[Index].DeviceName := ADeviceName;
        FResults[Index].Rssi := ARssi;
        Exit;
      end;
    Index := Length(FResults);
    SetLength(FResults, Index + 1);
    FResults[Index].DeviceId := ADeviceId;
    FResults[Index].DeviceName := ADeviceName;
    FResults[Index].Rssi := ARssi;
  finally
    LeaveCriticalSection(FResultsLock);
  end;
end;

function TBleScanOperation.GetResults: TBleDeviceInfos;
begin
  EnterCriticalSection(FResultsLock);
  try
    Result := Copy(FResults);
  finally
    LeaveCriticalSection(FResultsLock);
  end;
end;

constructor TBleSessionOperation.Create(const ASession: TBleGattSession;
  const AKind: TLazBleSessionOperationKind;
  const AOnCancel: TLazBleOperationCancelEvent);
begin
  inherited Create(AOnCancel);
  FSession := ASession;
  FKind := AKind;
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
  FConnectSession := AConnectSession;
  FDisconnectSession := ADisconnectSession;
  FSession := ASession;
  FProfiles := TList.Create;
  FOperations := TList.Create;
  FReconnectController := TLazBleReconnectController.Create(
    AReconnectTimer);
  FReconnectController.OnElapsed := @ReconnectDelayElapsed;
  FState := lbcstDisconnected;
  FSession.AddStateChangedHandler(@SessionStateChanged);
end;

destructor TBleClient.Destroy;
var
  Entry: TBleClientProfileEntry;
  Index: Integer;
begin
  FOnStateChanged := nil;
  FShuttingDown := True;
  FReconnectCycleActive := False;
  FReconnectController.OnElapsed := nil;
  FReconnectController.Disable;
  if Assigned(FSessionConnectOperation) then
    FSessionConnectOperation.OnCompleted := nil;
  if Assigned(FSessionDisconnectOperation) then
    FSessionDisconnectOperation.OnCompleted := nil;
  if Assigned(FSession) then
    FSession.RemoveStateChangedHandler(@SessionStateChanged);
  for Index := FProfiles.Count - 1 downto 0 do
  begin
    Entry := TBleClientProfileEntry(FProfiles[Index]);
    Entry.Profile.RemoveStateChangedHandler(@ProfileStateChanged);
    Entry.Profile.Detach;
    Entry.Profile.Free;
    Entry.Free;
  end;
  FProfiles.Free;
  for Index := FOperations.Count - 1 downto 0 do
    TObject(FOperations[Index]).Free;
  FOperations.Free;
  FReconnectController.Free;
  FSession := nil;
  FConnectSession := nil;
  FDisconnectSession := nil;
  inherited Destroy;
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
    if FState = lbcstWaitingToReconnect then
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
begin
  if FState = AState then
    Exit;
  FState := AState;
  if Assigned(FOnStateChanged) then
    FOnStateChanged(Self, FState);
end;

procedure TBleClient.AddProfile(const AProfile: TBleGattProfile;
  const ARequired: Boolean);
var
  Entry: TBleClientProfileEntry;
  Index: Integer;
begin
  if not Assigned(AProfile) then
    raise EArgumentNilException.Create('AProfile');
  if FState <> lbcstDisconnected then
    raise EInvalidOperation.Create(
      'Profiles can only be added while disconnected');
  if AProfile.Bound then
    raise EInvalidOperation.Create('Profile is already bound to a client');
  for Index := 0 to FProfiles.Count - 1 do
    if TBleClientProfileEntry(FProfiles[Index]).Profile = AProfile then
      raise EInvalidOperation.Create('Profile is already registered');
  Entry := TBleClientProfileEntry.Create;
  try
    TBleGattProfileAccess(AProfile).BindSession(FSession);
    Entry.Profile := AProfile;
    Entry.Required := ARequired;
    AProfile.AddStateChangedHandler(@ProfileStateChanged);
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
      TBleClientProfileEntry(FProfiles[Index]).Profile.Attach;
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
    TBleClientProfileEntry(FProfiles[Index]).Profile.Detach;
end;

procedure TBleClient.EvaluateProfiles;
var
  AllRequiredReady: Boolean;
  Entry: TBleClientProfileEntry;
  Index: Integer;
begin
  if FAttachingProfiles or FEvaluatingProfiles or
    not (FState in [lbcstAttachingProfiles, lbcstReady]) then
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
            SetState(lbcstError);
            if Assigned(FConnectOperation) then
              FConnectOperation.Complete(lbopFailed, 0,
                Entry.Profile.ClassName + ': ' +
                Entry.Profile.ErrorMessage);
            if FReconnectCycleActive then
              DisconnectForReconnect;
            Exit;
          end;
        lbgpsReady:
          ;
        else
          AllRequiredReady := False;
      end;
    end;
    if AllRequiredReady and (FState = lbcstAttachingProfiles) then
    begin
      FReconnectCycleActive := False;
      FReconnectController.Reset;
      SetState(lbcstReady);
      if Assigned(FConnectOperation) then
        FConnectOperation.Complete(lbopSucceeded);
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
begin
  if Sender <> FSessionConnectOperation then
    Exit;
  if FSessionConnectOperation.State = lbopSucceeded then
    AttachProfiles
  else
  begin
    SetState(lbcstError);
    if Assigned(FConnectOperation) then
      if FSessionConnectOperation.State = lbopCancelled then
        FConnectOperation.Complete(lbopCancelled)
      else
        FConnectOperation.Complete(lbopFailed,
          FSessionConnectOperation.ErrorCode,
          FSessionConnectOperation.ErrorMessage);
    if FReconnectCycleActive then
      ScheduleReconnect;
  end;
end;

procedure TBleClient.SessionDisconnectCompleted(Sender: TObject);
begin
  if Sender <> FSessionDisconnectOperation then
    Exit;
  if FSessionDisconnectOperation.State = lbopSucceeded then
  begin
    SetState(lbcstDisconnected);
    if Assigned(FDisconnectOperation) then
      FDisconnectOperation.Complete(lbopSucceeded);
  end
  else
  begin
    SetState(lbcstError);
    if Assigned(FDisconnectOperation) then
      FDisconnectOperation.Complete(lbopFailed,
        FSessionDisconnectOperation.ErrorCode,
        FSessionDisconnectOperation.ErrorMessage);
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
      (FState = lbcstReady) or
      ((FState = lbcstError) and
      (FReconnectController.Attempt > 0)));
    DetachProfiles;
    SetState(lbcstDisconnected);
    if Assigned(FConnectOperation) and
      (FConnectOperation.State = lbopPending) then
      if FConnectOperation.CancelRequested then
        FConnectOperation.Complete(lbopCancelled)
      else
        FConnectOperation.Complete(lbopFailed, 0,
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
  if Sender = FConnectOperation then
  begin
    if Assigned(FSessionConnectOperation) and
      (FSessionConnectOperation.State = lbopPending) then
      FSessionConnectOperation.Cancel
    else
    begin
      DetachProfiles;
      FDisconnectSession(FSession);
      FConnectOperation.Complete(lbopCancelled);
    end;
  end
  else if Sender = FDisconnectOperation then
    FDisconnectOperation.Complete(lbopCancelled);
end;

procedure TBleClient.CancelForShutdown;
begin
  FShuttingDown := True;
  FManualDisconnect := True;
  FReconnectCycleActive := False;
  FReconnectController.Disable;
  if FState = lbcstWaitingToReconnect then
    SetState(lbcstDisconnected);
  if Assigned(FConnectOperation) and
    (FConnectOperation.State = lbopPending) then
    FConnectOperation.Cancel;
  if Assigned(FDisconnectOperation) and
    (FDisconnectOperation.State = lbopPending) then
    FDisconnectOperation.Cancel;
end;

function TBleClient.ConnectAsync: TBleOperation;
begin
  Result := StartConnect(True);
end;

function TBleClient.StartConnect(const AManual: Boolean): TBleOperation;
begin
  if Assigned(FConnectOperation) and
    (FConnectOperation.State = lbopPending) then
    Exit(FConnectOperation);
  if AManual then
  begin
    FManualDisconnect := False;
    FReconnectCycleActive := False;
    FReconnectController.Reset;
    if FState = lbcstWaitingToReconnect then
      SetState(lbcstDisconnected);
  end;
  if not AManual and (FState = lbcstWaitingToReconnect) then
    SetState(lbcstDisconnected);
  Result := TBleOperation.Create(@OperationCancelled);
  FOperations.Add(Result);
  FConnectOperation := Result;
  if FState = lbcstReady then
  begin
    Result.Complete(lbopSucceeded);
    Exit;
  end;
  if FState <> lbcstDisconnected then
  begin
    Result.Complete(lbopFailed, 0,
      'BLE connection must be disconnected before connecting');
    Exit;
  end;
  SetState(lbcstConnecting);
  FSessionConnectOperation := FConnectSession(DeviceId);
  FSessionConnectOperation.OnCompleted := @SessionConnectCompleted;
end;

function TBleClient.DisconnectAsync: TBleOperation;
begin
  FManualDisconnect := True;
  FReconnectCycleActive := False;
  FReconnectController.Reset;
  if Assigned(FDisconnectOperation) and
    (FDisconnectOperation.State = lbopPending) then
    Exit(FDisconnectOperation);
  Result := TBleOperation.Create(@OperationCancelled);
  FOperations.Add(Result);
  FDisconnectOperation := Result;
  if FState in [lbcstDisconnected, lbcstWaitingToReconnect] then
  begin
    SetState(lbcstDisconnected);
    Result.Complete(lbopSucceeded);
    Exit;
  end;
  SetState(lbcstDisconnecting);
  DetachProfiles;
  FSessionDisconnectOperation := FDisconnectSession(FSession);
  FSessionDisconnectOperation.OnCompleted := @SessionDisconnectCompleted;
end;

function TBleClient.ReadAsync(const AServiceUuid,
  ACharacteristicUuid: string): TBleGattOperation;
begin
  Result := FSession.ReadAsync(AServiceUuid, ACharacteristicUuid);
end;

function TBleClient.WriteAsync(const AServiceUuid,
  ACharacteristicUuid: string; const AValue: TBytes;
  const AWriteMode: TLazBleWriteMode): TBleGattOperation;
begin
  Result := FSession.WriteAsync(AServiceUuid, ACharacteristicUuid, AValue,
    AWriteMode);
end;

function TBleClient.SubscribeAsync(const AServiceUuid,
  ACharacteristicUuid: string): TBleSubscription;
begin
  Result := FSession.SubscribeAsync(AServiceUuid, ACharacteristicUuid);
end;

end.
