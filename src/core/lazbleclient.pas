unit LazBleClient;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  LazBleTypes,
  LazBleBackend,
  LazBleGattSession,
  LazBleGattProfile,
  LazBleCentralManager;

type
  TLazBleClientOperationState = (
    lbcopsPending,
    lbcopsSucceeded,
    lbcopsFailed,
    lbcopsCancelled,
    lbcopsTimedOut
  );

  TLazBleClientOperationCompletedEvent = procedure(Sender: TObject) of object;
  TLazBleClientOperationCancelEvent = procedure(Sender: TObject) of object;

  TBleClientOperation = class
  private
    FLock: TRTLCriticalSection;
    FCallbackLock: TRTLCriticalSection;
    FState: TLazBleClientOperationState;
    FErrorCode: Integer;
    FErrorMessage: string;
    FCancelRequested: Boolean;
    FOnCancel: TLazBleClientOperationCancelEvent;
    FOnCompleted: TLazBleClientOperationCompletedEvent;
    function GetState: TLazBleClientOperationState;
    function GetErrorCode: Integer;
    function GetErrorMessage: string;
    function GetCancelRequested: Boolean;
    procedure SetOnCompleted(
      const AHandler: TLazBleClientOperationCompletedEvent);
    procedure Complete(const AState: TLazBleClientOperationState;
      const AErrorCode: Integer = 0; const AErrorMessage: string = '');
  public
    constructor Create(const AOnCancel: TLazBleClientOperationCancelEvent);
    destructor Destroy; override;
    procedure Cancel;
    procedure Timeout;
    property State: TLazBleClientOperationState read GetState;
    property ErrorCode: Integer read GetErrorCode;
    property ErrorMessage: string read GetErrorMessage;
    property CancelRequested: Boolean read GetCancelRequested;
    property OnCompleted: TLazBleClientOperationCompletedEvent
      read FOnCompleted write SetOnCompleted;
  end;

  TBleScanOperation = class(TBleClientOperation)
  private
    FResultsLock: TRTLCriticalSection;
    FResults: TBleDeviceInfos;
    procedure AddOrUpdateResult(const ADeviceId, ADeviceName: string;
      const ARssi: SmallInt);
    function GetResults: TBleDeviceInfos;
  public
    constructor Create(const AOnCancel: TLazBleClientOperationCancelEvent);
    destructor Destroy; override;
    property Results: TBleDeviceInfos read GetResults;
  end;

  TLazBleConnectionOperationKind = (
    lbcokConnect,
    lbcokDisconnect
  );

  TBleConnectionOperation = class(TBleClientOperation)
  private
    FKind: TLazBleConnectionOperationKind;
    FSession: TBleGattSession;
  public
    constructor Create(const ASession: TBleGattSession;
      const AKind: TLazBleConnectionOperationKind;
      const AOnCancel: TLazBleClientOperationCancelEvent);
    property Kind: TLazBleConnectionOperationKind read FKind;
    property Session: TBleGattSession read FSession;
  end;

  TLazBleConnectionState = (
    lbcosDisconnected,
    lbcosConnecting,
    lbcosAttachingProfiles,
    lbcosReady,
    lbcosDisconnecting,
    lbcosError
  );

  TLazBleConnectionStateChangedEvent = procedure(Sender: TObject;
    const AState: TLazBleConnectionState) of object;

  TBleClient = class;

  TBleConnection = class
  private
    FClient: TBleClient;
    FSession: TBleGattSession;
    FProfiles: TList;
    FOperations: TList;
    FState: TLazBleConnectionState;
    FAttachingProfiles: Boolean;
    FEvaluatingProfiles: Boolean;
    FConnectOperation: TBleClientOperation;
    FDisconnectOperation: TBleClientOperation;
    FSessionConnectOperation: TBleConnectionOperation;
    FSessionDisconnectOperation: TBleConnectionOperation;
    FOnStateChanged: TLazBleConnectionStateChangedEvent;
    function GetDeviceId: string;
    function GetProfileCount: Integer;
    function GetProfile(const AIndex: Integer): TBleGattProfile;
    procedure SetState(const AState: TLazBleConnectionState);
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
  public
    constructor Create(const AClient: TBleClient;
      const ASession: TBleGattSession);
    destructor Destroy; override;
    procedure AddProfile(const AProfile: TBleGattProfile;
      const ARequired: Boolean = True);
    function ConnectAsync: TBleClientOperation;
    function DisconnectAsync: TBleClientOperation;
    property DeviceId: string read GetDeviceId;
    property Session: TBleGattSession read FSession;
    property Profiles[const AIndex: Integer]: TBleGattProfile read GetProfile;
    property ProfileCount: Integer read GetProfileCount;
    property State: TLazBleConnectionState read FState;
    property OnStateChanged: TLazBleConnectionStateChangedEvent
      read FOnStateChanged write FOnStateChanged;
  end;

  TBleClient = class
  private
    FManager: TBleCentralManager;
    FOperations: TList;
    FConnections: TList;
    FActiveScan: TBleScanOperation;
    FShutdownOperation: TBleClientOperation;
    procedure OperationCancelled(Sender: TObject);
    procedure ScanResult(Sender: TObject; const ADeviceId,
      ADeviceName: string; const ARssi: SmallInt);
    procedure ScanCompleted(Sender: TObject; const ASucceeded: Boolean;
      const AErrorCode: Integer; const AErrorMessage: string);
    procedure SessionStateChanged(Sender: TObject;
      const AState: TLazBleSessionState);
    procedure ManagerStateChanged(Sender: TObject;
      const AState: TLazBleCentralState);
    procedure CompleteSessionOperations(const ASession: TBleGattSession;
      const AState: TLazBleSessionState);
  public
    constructor Create; overload;
    constructor Create(const ABackend: ILazBleBackend); overload;
    destructor Destroy; override;
    function ScanAsync(const AAdapterId: string;
      const ATimeoutMs: Cardinal): TBleScanOperation;
    function CreateConnection(const ADeviceId: string): TBleConnection;
    function ConnectAsync(const ADeviceId: string): TBleConnectionOperation;
    function DisconnectAsync(const ASession: TBleGattSession):
      TBleConnectionOperation;
    function ShutdownAsync: TBleClientOperation;
    property Manager: TBleCentralManager read FManager;
  end;

implementation

uses
  LazBleSimpleBleBackend;

type
  TBleConnectionProfileEntry = class
  public
    Profile: TBleGattProfile;
    Required: Boolean;
  end;

constructor TBleClientOperation.Create(
  const AOnCancel: TLazBleClientOperationCancelEvent);
begin
  inherited Create;
  InitCriticalSection(FLock);
  InitCriticalSection(FCallbackLock);
  FState := lbcopsPending;
  FOnCancel := AOnCancel;
end;

destructor TBleClientOperation.Destroy;
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

function TBleClientOperation.GetState: TLazBleClientOperationState;
begin
  EnterCriticalSection(FLock);
  try
    Result := FState;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TBleClientOperation.GetErrorCode: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Result := FErrorCode;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TBleClientOperation.GetErrorMessage: string;
begin
  EnterCriticalSection(FLock);
  try
    Result := FErrorMessage;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TBleClientOperation.GetCancelRequested: Boolean;
begin
  EnterCriticalSection(FLock);
  try
    Result := FCancelRequested;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TBleClientOperation.SetOnCompleted(
  const AHandler: TLazBleClientOperationCompletedEvent);
var
  NotifyNow: Boolean;
begin
  EnterCriticalSection(FCallbackLock);
  try
    EnterCriticalSection(FLock);
    try
      FOnCompleted := AHandler;
      NotifyNow := Assigned(AHandler) and (FState <> lbcopsPending);
    finally
      LeaveCriticalSection(FLock);
    end;
    if NotifyNow then
      AHandler(Self);
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
end;

procedure TBleClientOperation.Complete(
  const AState: TLazBleClientOperationState; const AErrorCode: Integer;
  const AErrorMessage: string);
var
  CompletedHandler: TLazBleClientOperationCompletedEvent;
begin
  EnterCriticalSection(FLock);
  try
    if FState <> lbcopsPending then
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

procedure TBleClientOperation.Cancel;
var
  CancelHandler: TLazBleClientOperationCancelEvent;
begin
  EnterCriticalSection(FLock);
  try
    if (FState <> lbcopsPending) or FCancelRequested then
      Exit;
    FCancelRequested := True;
    CancelHandler := FOnCancel;
  finally
    LeaveCriticalSection(FLock);
  end;
  if Assigned(CancelHandler) then
    CancelHandler(Self)
  else
    Complete(lbcopsCancelled);
end;

procedure TBleClientOperation.Timeout;
var
  CancelHandler: TLazBleClientOperationCancelEvent;
  CompletedHandler: TLazBleClientOperationCompletedEvent;
begin
  EnterCriticalSection(FLock);
  try
    if FState <> lbcopsPending then
      Exit;
    FCancelRequested := True;
    FState := lbcopsTimedOut;
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
  const AOnCancel: TLazBleClientOperationCancelEvent);
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

constructor TBleConnectionOperation.Create(const ASession: TBleGattSession;
  const AKind: TLazBleConnectionOperationKind;
  const AOnCancel: TLazBleClientOperationCancelEvent);
begin
  inherited Create(AOnCancel);
  FSession := ASession;
  FKind := AKind;
end;

constructor TBleConnection.Create(const AClient: TBleClient;
  const ASession: TBleGattSession);
begin
  inherited Create;
  if not Assigned(AClient) then
    raise EArgumentNilException.Create('AClient');
  if not Assigned(ASession) then
    raise EArgumentNilException.Create('ASession');
  FClient := AClient;
  FSession := ASession;
  FProfiles := TList.Create;
  FOperations := TList.Create;
  FState := lbcosDisconnected;
  FSession.AddStateChangedHandler(@SessionStateChanged);
end;

destructor TBleConnection.Destroy;
var
  Entry: TBleConnectionProfileEntry;
  Index: Integer;
begin
  FOnStateChanged := nil;
  if Assigned(FSessionConnectOperation) then
    FSessionConnectOperation.OnCompleted := nil;
  if Assigned(FSessionDisconnectOperation) then
    FSessionDisconnectOperation.OnCompleted := nil;
  if Assigned(FSession) then
    FSession.RemoveStateChangedHandler(@SessionStateChanged);
  for Index := FProfiles.Count - 1 downto 0 do
  begin
    Entry := TBleConnectionProfileEntry(FProfiles[Index]);
    Entry.Profile.RemoveStateChangedHandler(@ProfileStateChanged);
    Entry.Profile.Detach;
    Entry.Profile.Free;
    Entry.Free;
  end;
  FProfiles.Free;
  for Index := FOperations.Count - 1 downto 0 do
    TObject(FOperations[Index]).Free;
  FOperations.Free;
  FSession := nil;
  FClient := nil;
  inherited Destroy;
end;

function TBleConnection.GetDeviceId: string;
begin
  if Assigned(FSession) then
    Result := FSession.DeviceId
  else
    Result := '';
end;

function TBleConnection.GetProfileCount: Integer;
begin
  Result := FProfiles.Count;
end;

function TBleConnection.GetProfile(const AIndex: Integer): TBleGattProfile;
begin
  Result := TBleConnectionProfileEntry(FProfiles[AIndex]).Profile;
end;

procedure TBleConnection.SetState(const AState: TLazBleConnectionState);
begin
  if FState = AState then
    Exit;
  FState := AState;
  if Assigned(FOnStateChanged) then
    FOnStateChanged(Self, FState);
end;

procedure TBleConnection.AddProfile(const AProfile: TBleGattProfile;
  const ARequired: Boolean);
var
  Entry: TBleConnectionProfileEntry;
  Index: Integer;
begin
  if not Assigned(AProfile) then
    raise EArgumentNilException.Create('AProfile');
  if AProfile.Session <> FSession then
    raise EArgumentException.Create(
      'Profile must use the connection GATT session');
  if FState <> lbcosDisconnected then
    raise EInvalidOperation.Create(
      'Profiles can only be added while disconnected');
  for Index := 0 to FProfiles.Count - 1 do
    if TBleConnectionProfileEntry(FProfiles[Index]).Profile = AProfile then
      raise EInvalidOperation.Create('Profile is already registered');
  Entry := TBleConnectionProfileEntry.Create;
  Entry.Profile := AProfile;
  Entry.Required := ARequired;
  AProfile.AddStateChangedHandler(@ProfileStateChanged);
  FProfiles.Add(Entry);
end;

procedure TBleConnection.AttachProfiles;
var
  Index: Integer;
begin
  SetState(lbcosAttachingProfiles);
  FAttachingProfiles := True;
  try
    for Index := 0 to FProfiles.Count - 1 do
      TBleConnectionProfileEntry(FProfiles[Index]).Profile.Attach;
  finally
    FAttachingProfiles := False;
  end;
  EvaluateProfiles;
end;

procedure TBleConnection.DetachProfiles;
var
  Index: Integer;
begin
  for Index := FProfiles.Count - 1 downto 0 do
    TBleConnectionProfileEntry(FProfiles[Index]).Profile.Detach;
end;

procedure TBleConnection.EvaluateProfiles;
var
  AllRequiredReady: Boolean;
  Entry: TBleConnectionProfileEntry;
  Index: Integer;
begin
  if FAttachingProfiles or FEvaluatingProfiles or
    not (FState in [lbcosAttachingProfiles, lbcosReady]) then
    Exit;
  FEvaluatingProfiles := True;
  try
    AllRequiredReady := True;
    for Index := 0 to FProfiles.Count - 1 do
    begin
      Entry := TBleConnectionProfileEntry(FProfiles[Index]);
      if not Entry.Required then
        Continue;
      case Entry.Profile.State of
        lbgpsError:
          begin
            SetState(lbcosError);
            if Assigned(FConnectOperation) then
              FConnectOperation.Complete(lbcopsFailed, 0,
                Entry.Profile.ClassName + ': ' +
                Entry.Profile.ErrorMessage);
            Exit;
          end;
        lbgpsReady:
          ;
        else
          AllRequiredReady := False;
      end;
    end;
    if AllRequiredReady and (FState = lbcosAttachingProfiles) then
    begin
      SetState(lbcosReady);
      if Assigned(FConnectOperation) then
        FConnectOperation.Complete(lbcopsSucceeded);
    end;
  finally
    FEvaluatingProfiles := False;
  end;
end;

procedure TBleConnection.ProfileStateChanged(Sender: TObject;
  const AState: TLazBleGattProfileState);
begin
  EvaluateProfiles;
end;

procedure TBleConnection.SessionConnectCompleted(Sender: TObject);
begin
  if Sender <> FSessionConnectOperation then
    Exit;
  if FSessionConnectOperation.State = lbcopsSucceeded then
    AttachProfiles
  else
  begin
    SetState(lbcosError);
    if Assigned(FConnectOperation) then
      if FSessionConnectOperation.State = lbcopsCancelled then
        FConnectOperation.Complete(lbcopsCancelled)
      else
        FConnectOperation.Complete(lbcopsFailed,
          FSessionConnectOperation.ErrorCode,
          FSessionConnectOperation.ErrorMessage);
  end;
end;

procedure TBleConnection.SessionDisconnectCompleted(Sender: TObject);
begin
  if Sender <> FSessionDisconnectOperation then
    Exit;
  if FSessionDisconnectOperation.State = lbcopsSucceeded then
  begin
    SetState(lbcosDisconnected);
    if Assigned(FDisconnectOperation) then
      FDisconnectOperation.Complete(lbcopsSucceeded);
  end
  else
  begin
    SetState(lbcosError);
    if Assigned(FDisconnectOperation) then
      FDisconnectOperation.Complete(lbcopsFailed,
        FSessionDisconnectOperation.ErrorCode,
        FSessionDisconnectOperation.ErrorMessage);
  end;
end;

procedure TBleConnection.SessionStateChanged(Sender: TObject;
  const AState: TLazBleSessionState);
begin
  if Sender <> FSession then
    Exit;
  if AState = lbssDisconnected then
  begin
    DetachProfiles;
    SetState(lbcosDisconnected);
    if Assigned(FConnectOperation) and
      (FConnectOperation.State = lbcopsPending) then
      if FConnectOperation.CancelRequested then
        FConnectOperation.Complete(lbcopsCancelled)
      else
        FConnectOperation.Complete(lbcopsFailed, 0,
          'BLE connection was closed');
  end;
end;

procedure TBleConnection.OperationCancelled(Sender: TObject);
begin
  if Sender = FConnectOperation then
  begin
    if Assigned(FSessionConnectOperation) and
      (FSessionConnectOperation.State = lbcopsPending) then
      FSessionConnectOperation.Cancel
    else
    begin
      DetachProfiles;
      FClient.DisconnectAsync(FSession);
      FConnectOperation.Complete(lbcopsCancelled);
    end;
  end
  else if Sender = FDisconnectOperation then
    FDisconnectOperation.Complete(lbcopsCancelled);
end;

function TBleConnection.ConnectAsync: TBleClientOperation;
begin
  if Assigned(FConnectOperation) and
    (FConnectOperation.State = lbcopsPending) then
    Exit(FConnectOperation);
  Result := TBleClientOperation.Create(@OperationCancelled);
  FOperations.Add(Result);
  FConnectOperation := Result;
  if FState = lbcosReady then
  begin
    Result.Complete(lbcopsSucceeded);
    Exit;
  end;
  if FState <> lbcosDisconnected then
  begin
    Result.Complete(lbcopsFailed, 0,
      'BLE connection must be disconnected before connecting');
    Exit;
  end;
  SetState(lbcosConnecting);
  FSessionConnectOperation := FClient.ConnectAsync(DeviceId);
  FSessionConnectOperation.OnCompleted := @SessionConnectCompleted;
end;

function TBleConnection.DisconnectAsync: TBleClientOperation;
begin
  if Assigned(FDisconnectOperation) and
    (FDisconnectOperation.State = lbcopsPending) then
    Exit(FDisconnectOperation);
  Result := TBleClientOperation.Create(@OperationCancelled);
  FOperations.Add(Result);
  FDisconnectOperation := Result;
  if FState = lbcosDisconnected then
  begin
    Result.Complete(lbcopsSucceeded);
    Exit;
  end;
  SetState(lbcosDisconnecting);
  DetachProfiles;
  FSessionDisconnectOperation := FClient.DisconnectAsync(FSession);
  FSessionDisconnectOperation.OnCompleted := @SessionDisconnectCompleted;
end;

constructor TBleClient.Create;
var
  Backend: ILazBleBackend;
begin
  Backend := TLazBleSimpleBleBackend.Create;
  Create(Backend);
end;

constructor TBleClient.Create(const ABackend: ILazBleBackend);
begin
  inherited Create;
  FOperations := TList.Create;
  FConnections := TList.Create;
  FManager := TBleCentralManager.Create(ABackend);
  FManager.OnScanResult := @ScanResult;
  FManager.OnScanCompleted := @ScanCompleted;
  FManager.OnStateChanged := @ManagerStateChanged;
end;

destructor TBleClient.Destroy;
var
  Index: Integer;
begin
  if Assigned(FManager) then
  begin
    FManager.OnScanResult := nil;
    FManager.OnScanCompleted := nil;
    FManager.OnStateChanged := nil;
  end;
  for Index := FConnections.Count - 1 downto 0 do
    TObject(FConnections[Index]).Free;
  FConnections.Free;
  for Index := 0 to FOperations.Count - 1 do
    if (TObject(FOperations[Index]) is TBleConnectionOperation) and
      Assigned(TBleConnectionOperation(FOperations[Index]).Session) then
      TBleConnectionOperation(FOperations[Index]).Session.OnStateChanged := nil;
  FManager.Free;
  FManager := nil;
  for Index := FOperations.Count - 1 downto 0 do
    TObject(FOperations[Index]).Free;
  FOperations.Free;
  inherited Destroy;
end;

procedure TBleClient.OperationCancelled(Sender: TObject);
var
  ConnectionOperation: TBleConnectionOperation;
begin
  if Sender = FActiveScan then
  begin
    FManager.CancelScan;
    Exit;
  end;
  if Sender is TBleConnectionOperation then
  begin
    ConnectionOperation := TBleConnectionOperation(Sender);
    if ConnectionOperation.Kind = lbcokConnect then
    begin
      if Assigned(ConnectionOperation.Session) then
        ConnectionOperation.Session.Disconnect;
    end
    else
      ConnectionOperation.Complete(lbcopsCancelled);
  end;
end;

procedure TBleClient.ScanResult(Sender: TObject; const ADeviceId,
  ADeviceName: string; const ARssi: SmallInt);
begin
  if Assigned(FActiveScan) and
    (FActiveScan.State = lbcopsPending) then
    FActiveScan.AddOrUpdateResult(ADeviceId, ADeviceName, ARssi);
end;

procedure TBleClient.ScanCompleted(Sender: TObject;
  const ASucceeded: Boolean; const AErrorCode: Integer;
  const AErrorMessage: string);
var
  Operation: TBleScanOperation;
begin
  Operation := FActiveScan;
  FActiveScan := nil;
  if not Assigned(Operation) then
    Exit;
  if Operation.CancelRequested then
    Operation.Complete(lbcopsCancelled)
  else if ASucceeded then
    Operation.Complete(lbcopsSucceeded)
  else
    Operation.Complete(lbcopsFailed, AErrorCode, AErrorMessage);
end;

procedure TBleClient.CompleteSessionOperations(
  const ASession: TBleGattSession; const AState: TLazBleSessionState);
var
  Index: Integer;
  Operation: TBleConnectionOperation;
begin
  for Index := 0 to FOperations.Count - 1 do
    if TObject(FOperations[Index]) is TBleConnectionOperation then
    begin
      Operation := TBleConnectionOperation(FOperations[Index]);
      if (Operation.Session <> ASession) or
        (Operation.State <> lbcopsPending) then
        Continue;
      case Operation.Kind of
        lbcokConnect:
          if AState = lbssConnected then
            Operation.Complete(lbcopsSucceeded)
          else if AState in [lbssDisconnected, lbssError] then
          begin
            if Operation.CancelRequested then
              Operation.Complete(lbcopsCancelled)
            else
              Operation.Complete(lbcopsFailed, 0,
                'Could not connect and discover GATT services');
          end;
        lbcokDisconnect:
          if AState = lbssDisconnected then
            Operation.Complete(lbcopsSucceeded)
          else if AState = lbssError then
            Operation.Complete(lbcopsFailed, 0,
              'Could not disconnect BLE session');
      end;
    end;
end;

procedure TBleClient.SessionStateChanged(Sender: TObject;
  const AState: TLazBleSessionState);
begin
  if Sender is TBleGattSession then
    CompleteSessionOperations(TBleGattSession(Sender), AState);
end;

procedure TBleClient.ManagerStateChanged(Sender: TObject;
  const AState: TLazBleCentralState);
begin
  if Assigned(FShutdownOperation) and (AState = lbcsShutdown) then
    FShutdownOperation.Complete(lbcopsSucceeded);
end;

function TBleClient.ScanAsync(const AAdapterId: string;
  const ATimeoutMs: Cardinal): TBleScanOperation;
begin
  if Assigned(FActiveScan) and
    (FActiveScan.State = lbcopsPending) then
    Exit(FActiveScan);
  Result := TBleScanOperation.Create(@OperationCancelled);
  FOperations.Add(Result);
  FActiveScan := Result;
  if FManager.StartScan(AAdapterId, ATimeoutMs) = InvalidBleOperationId then
  begin
    FActiveScan := nil;
    Result.Complete(lbcopsFailed, 0, 'Could not start BLE scan');
  end;
end;

function TBleClient.CreateConnection(
  const ADeviceId: string): TBleConnection;
var
  Index: Integer;
  Session: TBleGattSession;
begin
  for Index := 0 to FConnections.Count - 1 do
  begin
    Result := TBleConnection(FConnections[Index]);
    if Result.DeviceId = ADeviceId then
      Exit;
  end;
  Session := FManager.CreateSession(ADeviceId);
  if not Assigned(Session) then
    Exit(nil);
  Result := TBleConnection.Create(Self, Session);
  FConnections.Add(Result);
end;

function TBleClient.ConnectAsync(
  const ADeviceId: string): TBleConnectionOperation;
var
  Session: TBleGattSession;
begin
  Session := FManager.CreateSession(ADeviceId);
  Result := TBleConnectionOperation.Create(Session, lbcokConnect,
    @OperationCancelled);
  FOperations.Add(Result);
  if not Assigned(Session) then
  begin
    Result.Complete(lbcopsFailed, 0, 'Could not create BLE session');
    Exit;
  end;
  Session.OnStateChanged := @SessionStateChanged;
  if Session.State = lbssConnected then
    Result.Complete(lbcopsSucceeded)
  else if Session.Connect = InvalidBleOperationId then
    Result.Complete(lbcopsFailed, 0, 'Could not start BLE connection');
end;

function TBleClient.DisconnectAsync(const ASession: TBleGattSession):
  TBleConnectionOperation;
begin
  Result := TBleConnectionOperation.Create(ASession, lbcokDisconnect,
    @OperationCancelled);
  FOperations.Add(Result);
  if not Assigned(ASession) then
  begin
    Result.Complete(lbcopsFailed, 0, 'BLE session is not assigned');
    Exit;
  end;
  ASession.OnStateChanged := @SessionStateChanged;
  if ASession.State = lbssDisconnected then
    Result.Complete(lbcopsSucceeded)
  else if ASession.Disconnect = InvalidBleOperationId then
    Result.Complete(lbcopsFailed, 0, 'Could not start BLE disconnect');
end;

function TBleClient.ShutdownAsync: TBleClientOperation;
begin
  if Assigned(FShutdownOperation) then
    Exit(FShutdownOperation);
  FShutdownOperation := TBleClientOperation.Create(nil);
  FOperations.Add(FShutdownOperation);
  if FManager.State = lbcsShutdown then
    FShutdownOperation.Complete(lbcopsSucceeded)
  else if FManager.BeginShutdown = InvalidBleOperationId then
    FShutdownOperation.Complete(lbcopsFailed, 0,
      'Could not start BLE shutdown');
  Result := FShutdownOperation;
end;

end.
