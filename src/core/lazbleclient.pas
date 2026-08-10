unit LazBleClient;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  LazBleTypes,
  LazBleBackend,
  LazBleGattOperation,
  LazBleGattSubscription,
  LazBleGattSession,
  LazBleGattProfile,
  LazBleCentralManager;

type
  ELazBleDuplicateClient = class(Exception);

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
    procedure AddOrUpdateResult(const ADeviceId, ADeviceName: string;
      const ARssi: SmallInt);
    function GetResults: TBleDeviceInfos;
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

  TLazBleClientState = (
    lbcstDisconnected,
    lbcstConnecting,
    lbcstAttachingProfiles,
    lbcstReady,
    lbcstDisconnecting,
    lbcstError
  );

  TLazBleClientStateChangedEvent = procedure(Sender: TObject;
    const AState: TLazBleClientState) of object;

  TLazBle = class;

  TBleClient = class
  private
    FBle: TLazBle;
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
  public
    { Applications obtain clients from TLazBle.CreateClient. }
    constructor Create(const ABle: TLazBle;
      const ASession: TBleGattSession);
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
    property OnStateChanged: TLazBleClientStateChangedEvent
      read FOnStateChanged write FOnStateChanged;
  end;

  TLazBle = class
  private
    FManager: TBleCentralManager;
    FOperations: TList;
    FClients: TList;
    FActiveScan: TBleScanOperation;
    FShutdownOperation: TBleOperation;
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
    function ConnectAsync(const ADeviceId: string): TBleSessionOperation;
    function DisconnectAsync(const ASession: TBleGattSession):
      TBleSessionOperation;
  public
    constructor Create; overload;
    constructor Create(const ABackend: ILazBleBackend); overload;
    destructor Destroy; override;
    function ScanAsync(const AAdapterId: string;
      const ATimeoutMs: Cardinal): TBleScanOperation;
    function CreateClient(const ADeviceId: string): TBleClient;
    function FindClient(const ADeviceId: string): TBleClient;
    procedure RemoveClient(const AClient: TBleClient);
    function ShutdownAsync: TBleOperation;
  end;

implementation

uses
  LazBleSimpleBleBackend;

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

constructor TBleClient.Create(const ABle: TLazBle;
  const ASession: TBleGattSession);
begin
  inherited Create;
  if not Assigned(ABle) then
    raise EArgumentNilException.Create('ABle');
  if not Assigned(ASession) then
    raise EArgumentNilException.Create('ASession');
  FBle := ABle;
  FSession := ASession;
  FProfiles := TList.Create;
  FOperations := TList.Create;
  FState := lbcstDisconnected;
  FSession.AddStateChangedHandler(@SessionStateChanged);
end;

destructor TBleClient.Destroy;
var
  Entry: TBleClientProfileEntry;
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
  FSession := nil;
  FBle := nil;
  inherited Destroy;
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
  end;
end;

procedure TBleClient.SessionStateChanged(Sender: TObject;
  const AState: TLazBleSessionState);
begin
  if Sender <> FSession then
    Exit;
  if AState = lbssDisconnected then
  begin
    DetachProfiles;
    SetState(lbcstDisconnected);
    if Assigned(FConnectOperation) and
      (FConnectOperation.State = lbopPending) then
      if FConnectOperation.CancelRequested then
        FConnectOperation.Complete(lbopCancelled)
      else
        FConnectOperation.Complete(lbopFailed, 0,
          'BLE connection was closed');
  end;
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
      FBle.DisconnectAsync(FSession);
      FConnectOperation.Complete(lbopCancelled);
    end;
  end
  else if Sender = FDisconnectOperation then
    FDisconnectOperation.Complete(lbopCancelled);
end;

function TBleClient.ConnectAsync: TBleOperation;
begin
  if Assigned(FConnectOperation) and
    (FConnectOperation.State = lbopPending) then
    Exit(FConnectOperation);
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
  FSessionConnectOperation := FBle.ConnectAsync(DeviceId);
  FSessionConnectOperation.OnCompleted := @SessionConnectCompleted;
end;

function TBleClient.DisconnectAsync: TBleOperation;
begin
  if Assigned(FDisconnectOperation) and
    (FDisconnectOperation.State = lbopPending) then
    Exit(FDisconnectOperation);
  Result := TBleOperation.Create(@OperationCancelled);
  FOperations.Add(Result);
  FDisconnectOperation := Result;
  if FState = lbcstDisconnected then
  begin
    Result.Complete(lbopSucceeded);
    Exit;
  end;
  SetState(lbcstDisconnecting);
  DetachProfiles;
  FSessionDisconnectOperation := FBle.DisconnectAsync(FSession);
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

constructor TLazBle.Create;
var
  Backend: ILazBleBackend;
begin
  Backend := TLazBleSimpleBleBackend.Create;
  Create(Backend);
end;

constructor TLazBle.Create(const ABackend: ILazBleBackend);
begin
  inherited Create;
  FOperations := TList.Create;
  FClients := TList.Create;
  FManager := TBleCentralManager.Create(ABackend);
  FManager.OnScanResult := @ScanResult;
  FManager.OnScanCompleted := @ScanCompleted;
  FManager.OnStateChanged := @ManagerStateChanged;
end;

destructor TLazBle.Destroy;
var
  Index: Integer;
begin
  if Assigned(FManager) then
  begin
    FManager.OnScanResult := nil;
    FManager.OnScanCompleted := nil;
    FManager.OnStateChanged := nil;
  end;
  for Index := FClients.Count - 1 downto 0 do
    TObject(FClients[Index]).Free;
  FClients.Free;
  for Index := 0 to FOperations.Count - 1 do
    if (TObject(FOperations[Index]) is TBleSessionOperation) and
      Assigned(TBleSessionOperation(FOperations[Index]).Session) then
      TBleSessionOperation(FOperations[Index]).Session.OnStateChanged := nil;
  FManager.Free;
  FManager := nil;
  for Index := FOperations.Count - 1 downto 0 do
    TObject(FOperations[Index]).Free;
  FOperations.Free;
  inherited Destroy;
end;

procedure TLazBle.OperationCancelled(Sender: TObject);
var
  ConnectionOperation: TBleSessionOperation;
begin
  if Sender = FActiveScan then
  begin
    FManager.CancelScan;
    Exit;
  end;
  if Sender is TBleSessionOperation then
  begin
    ConnectionOperation := TBleSessionOperation(Sender);
    if ConnectionOperation.Kind = lbsokConnect then
    begin
      if Assigned(ConnectionOperation.Session) then
        ConnectionOperation.Session.Disconnect;
    end
    else
      ConnectionOperation.Complete(lbopCancelled);
  end;
end;

procedure TLazBle.ScanResult(Sender: TObject; const ADeviceId,
  ADeviceName: string; const ARssi: SmallInt);
begin
  if Assigned(FActiveScan) and
    (FActiveScan.State = lbopPending) then
    FActiveScan.AddOrUpdateResult(ADeviceId, ADeviceName, ARssi);
end;

procedure TLazBle.ScanCompleted(Sender: TObject;
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
    Operation.Complete(lbopCancelled)
  else if ASucceeded then
    Operation.Complete(lbopSucceeded)
  else
    Operation.Complete(lbopFailed, AErrorCode, AErrorMessage);
end;

procedure TLazBle.CompleteSessionOperations(
  const ASession: TBleGattSession; const AState: TLazBleSessionState);
var
  Index: Integer;
  Operation: TBleSessionOperation;
begin
  for Index := 0 to FOperations.Count - 1 do
    if TObject(FOperations[Index]) is TBleSessionOperation then
    begin
      Operation := TBleSessionOperation(FOperations[Index]);
      if (Operation.Session <> ASession) or
        (Operation.State <> lbopPending) then
        Continue;
      case Operation.Kind of
        lbsokConnect:
          if AState = lbssConnected then
            Operation.Complete(lbopSucceeded)
          else if AState in [lbssDisconnected, lbssError] then
          begin
            if Operation.CancelRequested then
              Operation.Complete(lbopCancelled)
            else
              Operation.Complete(lbopFailed, 0,
                'Could not connect and discover GATT services');
          end;
        lbsokDisconnect:
          if AState = lbssDisconnected then
            Operation.Complete(lbopSucceeded)
          else if AState = lbssError then
            Operation.Complete(lbopFailed, 0,
              'Could not disconnect BLE session');
      end;
    end;
end;

procedure TLazBle.SessionStateChanged(Sender: TObject;
  const AState: TLazBleSessionState);
begin
  if Sender is TBleGattSession then
    CompleteSessionOperations(TBleGattSession(Sender), AState);
end;

procedure TLazBle.ManagerStateChanged(Sender: TObject;
  const AState: TLazBleCentralState);
begin
  if Assigned(FShutdownOperation) and (AState = lbcsShutdown) then
    FShutdownOperation.Complete(lbopSucceeded);
end;

function TLazBle.ScanAsync(const AAdapterId: string;
  const ATimeoutMs: Cardinal): TBleScanOperation;
begin
  if Assigned(FActiveScan) and
    (FActiveScan.State = lbopPending) then
    Exit(FActiveScan);
  Result := TBleScanOperation.Create(@OperationCancelled);
  FOperations.Add(Result);
  FActiveScan := Result;
  if FManager.StartScan(AAdapterId, ATimeoutMs) = InvalidBleOperationId then
  begin
    FActiveScan := nil;
    Result.Complete(lbopFailed, 0, 'Could not start BLE scan');
  end;
end;

function TLazBle.FindClient(const ADeviceId: string): TBleClient;
var
  Index: Integer;
begin
  Result := nil;
  for Index := 0 to FClients.Count - 1 do
  begin
    Result := TBleClient(FClients[Index]);
    if SameText(Result.DeviceId, ADeviceId) then
      Exit;
  end;
  Result := nil;
end;

function TLazBle.CreateClient(const ADeviceId: string): TBleClient;
var
  Session: TBleGattSession;
begin
  if Assigned(FindClient(ADeviceId)) then
    raise ELazBleDuplicateClient.CreateFmt(
      'A BLE client already exists for device "%s"', [ADeviceId]);
  Session := FManager.CreateSession(ADeviceId);
  if not Assigned(Session) then
    Exit(nil);
  Result := TBleClient.Create(Self, Session);
  FClients.Add(Result);
end;

procedure TLazBle.RemoveClient(const AClient: TBleClient);
var
  Index: Integer;
begin
  if not Assigned(AClient) then
    raise EArgumentNilException.Create('AClient');
  Index := FClients.IndexOf(AClient);
  if Index < 0 then
    raise EArgumentException.Create('Client does not belong to this LazBle');
  if AClient.State <> lbcstDisconnected then
    raise EInvalidOperation.Create(
      'BLE client must be disconnected before it can be removed');
  FClients.Delete(Index);
  AClient.Free;
end;

function TLazBle.ConnectAsync(
  const ADeviceId: string): TBleSessionOperation;
var
  Session: TBleGattSession;
begin
  Session := FManager.CreateSession(ADeviceId);
  Result := TBleSessionOperation.Create(Session, lbsokConnect,
    @OperationCancelled);
  FOperations.Add(Result);
  if not Assigned(Session) then
  begin
    Result.Complete(lbopFailed, 0, 'Could not create BLE session');
    Exit;
  end;
  Session.OnStateChanged := @SessionStateChanged;
  if Session.State = lbssConnected then
    Result.Complete(lbopSucceeded)
  else if Session.Connect = InvalidBleOperationId then
    Result.Complete(lbopFailed, 0, 'Could not start BLE connection');
end;

function TLazBle.DisconnectAsync(const ASession: TBleGattSession):
  TBleSessionOperation;
begin
  Result := TBleSessionOperation.Create(ASession, lbsokDisconnect,
    @OperationCancelled);
  FOperations.Add(Result);
  if not Assigned(ASession) then
  begin
    Result.Complete(lbopFailed, 0, 'BLE session is not assigned');
    Exit;
  end;
  ASession.OnStateChanged := @SessionStateChanged;
  if ASession.State = lbssDisconnected then
    Result.Complete(lbopSucceeded)
  else if ASession.Disconnect = InvalidBleOperationId then
    Result.Complete(lbopFailed, 0, 'Could not start BLE disconnect');
end;

function TLazBle.ShutdownAsync: TBleOperation;
begin
  if Assigned(FShutdownOperation) then
    Exit(FShutdownOperation);
  FShutdownOperation := TBleOperation.Create(nil);
  FOperations.Add(FShutdownOperation);
  if FManager.State = lbcsShutdown then
    FShutdownOperation.Complete(lbopSucceeded)
  else if FManager.BeginShutdown = InvalidBleOperationId then
    FShutdownOperation.Complete(lbopFailed, 0,
      'Could not start BLE shutdown');
  Result := FShutdownOperation;
end;

end.
