unit LazBleFacade;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  LazBleTypes,
  LazBleBackend,
  LazBleOperation,
  LazBleGattSession,
  LazBleCentralManager,
  LazBleClientInternal,
  LazBleClient,
  LazBleReconnect;

type
  ELazBleDuplicateClient = class(Exception);

  { FPC-only facade. The default constructor selects the SimpleBLE backend;
    passing ILazBleBackend lets applications use another implementation.
    Creation and diagnostic reads do not start native BLE work. }
  TLazBle = class
  private
    FManager: TBleCentralManager;
    FOperations: TList;
    FClients: TList;
    FActiveScan: IBleScanOperation;
    FActiveScanObject: TBleScanOperation;
    FActiveAvailability: IBleAvailabilityOperation;
    FActiveAvailabilityObject: TBleAvailabilityOperation;
    FShutdownOperation: IBleOperation;
    FShutdownOperationObject: TBleOperation;
    FReconnectTimerFactory: ILazBleReconnectTimerFactory;
    FBackendInfoLock: TRTLCriticalSection;
    FBackendInfo: TLazBleBackendInfo;
    FBackendName: string;
    FAvailability: TBleAvailability;
    FAvailabilityError: string;
    function GetBackendInfo: TLazBleBackendInfo;
    function GetDiagnosticInfo: TLazBleDiagnosticInfo;
    procedure OperationCancelled(Sender: TObject);
    procedure ScanResult(Sender: TObject; const ADeviceId,
      ADeviceName: string; const ARssi: SmallInt);
    procedure ScanCompleted(Sender: TObject; const ASucceeded: Boolean;
      const AErrorCode: Integer; const AErrorMessage: string);
    procedure AvailabilityResult(Sender: TObject;
      const AAvailability: TBleAvailability;
      const ABackendInfo: TLazBleBackendInfo);
    procedure AvailabilityCompleted(Sender: TObject;
      const ASucceeded: Boolean; const AErrorCode: Integer;
      const AErrorMessage: string);
    procedure SessionStateChanged(Sender: TObject;
      const AState: TLazBleSessionState);
    procedure ManagerStateChanged(Sender: TObject;
      const AState: TLazBleCentralState);
    procedure CancelPendingOperations;
    procedure CompleteSessionOperations(const ASession: TBleGattSession;
      const AState: TLazBleSessionState);
    function ConnectSessionAsync(const ADeviceId: string):
      IBleOperation;
    function DisconnectSessionAsync(const ASession: TBleGattSession):
      IBleOperation;
  protected
    constructor Create(const ABackend: ILazBleBackend;
      const AReconnectTimerFactory: ILazBleReconnectTimerFactory); overload;
  public
    constructor Create; overload;
    constructor Create(const ABackend: ILazBleBackend); overload;
    destructor Destroy; override;
    { Returns an asynchronous scan operation; results and completion arrive
      through that operation. }
    function ScanAsync(const AAdapterId: string;
      const ATimeoutMs: Cardinal): IBleScanOperation;
    { Starts an explicit availability check. The diagnostic snapshot reflects
      its state and result; reading the snapshot does not start a check. }
    function CheckAvailabilityAsync(const AAdapterId: string):
      IBleAvailabilityOperation;
    { Creates a client owned by this facade for the given device ID. }
    function CreateClient(const ADeviceId: string): TBleClient;
    function FindClient(const ADeviceId: string): TBleClient;
    { Free a client owned by this facade. It must be disconnected or in error. }
    procedure RemoveClient(const AClient: TBleClient);
    { Stops backend work and completes after pending operations are drained. }
    function ShutdownAsync: IBleOperation;
    { Reading DiagnosticInfo never opens the native library or starts BLE.
      BackendName comes from ILazBleBackend.GetBackendName before a check,
      then from the backend's availability result when provided.
      Example: Info := Ble.DiagnosticInfo; after CheckAvailabilityAsync
      completes, Info.NativeVersion is the reported native version or ''. }
    property DiagnosticInfo: TLazBleDiagnosticInfo read GetDiagnosticInfo;
    { Availability-result metadata retained for compatibility. Version is
      native backend version, not the LazBle or Pascal binding version. }
    property BackendInfo: TLazBleBackendInfo read GetBackendInfo;
  end;

implementation

uses
  LazBleSimpleBleBackend,
  SimpleBle;

type
  TBleClientAccess = class(TBleClient)
  public
    constructor CreateInternal(const ASession: TBleGattSession;
      const AConnectSession: TLazBleConnectSessionEvent;
      const ADisconnectSession: TLazBleDisconnectSessionEvent;
      const AReconnectTimer: ILazBleReconnectTimer);
  end;

  TBleCentralManagerAccess = class(TBleCentralManager)
  public
    procedure DetachBackendEventsInternal;
  end;

  TBleGattSessionAccess = class(TBleGattSession)
  public
    function ConnectInternal: TBleOperationId;
    function DisconnectInternal: TBleOperationId;
  end;

  TBleOperationAccess = class(TBleOperation)
  public
    constructor CreateInternal(
      const AOnCancel: TLazBleOperationCancelEvent);
    procedure Finish(const AState: TLazBleOperationState;
      const AErrorCode: Integer = 0; const AErrorMessage: string = '');
  end;

  TBleScanOperationAccess = class(TBleScanOperation)
  public
    constructor CreateInternal(
      const AOnCancel: TLazBleOperationCancelEvent);
    procedure Finish(const AState: TLazBleOperationState;
      const AErrorCode: Integer = 0; const AErrorMessage: string = '');
    procedure AddResult(const ADeviceId, ADeviceName: string;
      const ARssi: SmallInt);
  end;

  TBleAvailabilityOperationAccess = class(TBleAvailabilityOperation)
  public
    constructor CreateInternal(
      const AOnCancel: TLazBleOperationCancelEvent);
    procedure Finish(const AState: TLazBleOperationState;
      const AErrorCode: Integer = 0; const AErrorMessage: string = '');
    procedure StoreAvailability(const AAvailability: TBleAvailability);
  end;

  TBleSessionOperationAccess = class(TBleSessionOperation)
  public
    procedure Finish(const AState: TLazBleOperationState;
      const AErrorCode: Integer = 0; const AErrorMessage: string = '');
  end;

  TBleSessionOperationEntry = class
  public
    Operation: IBleOperation;
    Instance: TBleSessionOperation;
  end;

constructor TBleClientAccess.CreateInternal(const ASession: TBleGattSession;
  const AConnectSession: TLazBleConnectSessionEvent;
  const ADisconnectSession: TLazBleDisconnectSessionEvent;
  const AReconnectTimer: ILazBleReconnectTimer);
begin
  inherited Create(ASession, AConnectSession, ADisconnectSession,
    AReconnectTimer);
end;

procedure TBleCentralManagerAccess.DetachBackendEventsInternal;
begin
  DetachBackendEvents;
end;

function TBleGattSessionAccess.ConnectInternal: TBleOperationId;
begin
  Result := Connect;
end;

function TBleGattSessionAccess.DisconnectInternal: TBleOperationId;
begin
  Result := Disconnect;
end;

constructor TBleOperationAccess.CreateInternal(
  const AOnCancel: TLazBleOperationCancelEvent);
begin
  inherited Create(AOnCancel);
end;

constructor TBleScanOperationAccess.CreateInternal(
  const AOnCancel: TLazBleOperationCancelEvent);
begin
  inherited Create(AOnCancel);
end;

constructor TBleAvailabilityOperationAccess.CreateInternal(
  const AOnCancel: TLazBleOperationCancelEvent);
begin
  inherited Create(AOnCancel);
end;

procedure TBleAvailabilityOperationAccess.Finish(
  const AState: TLazBleOperationState; const AErrorCode: Integer;
  const AErrorMessage: string);
begin
  Complete(AState, AErrorCode, AErrorMessage);
end;

procedure TBleAvailabilityOperationAccess.StoreAvailability(
  const AAvailability: TBleAvailability);
begin
  SetAvailability(AAvailability);
end;

procedure TBleOperationAccess.Finish(const AState: TLazBleOperationState;
  const AErrorCode: Integer; const AErrorMessage: string);
begin
  Complete(AState, AErrorCode, AErrorMessage);
end;

procedure TBleScanOperationAccess.AddResult(const ADeviceId,
  ADeviceName: string; const ARssi: SmallInt);
begin
  AddOrUpdateResult(ADeviceId, ADeviceName, ARssi);
end;

procedure TBleScanOperationAccess.Finish(const AState: TLazBleOperationState;
  const AErrorCode: Integer; const AErrorMessage: string);
begin
  Complete(AState, AErrorCode, AErrorMessage);
end;

procedure TBleSessionOperationAccess.Finish(
  const AState: TLazBleOperationState; const AErrorCode: Integer;
  const AErrorMessage: string);
begin
  Complete(AState, AErrorCode, AErrorMessage);
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
  Create(ABackend, LazBleCreateDefaultReconnectTimerFactory);
end;

constructor TLazBle.Create(const ABackend: ILazBleBackend;
  const AReconnectTimerFactory: ILazBleReconnectTimerFactory);
var
  BackendName: string;
begin
  inherited Create;
  if not Assigned(ABackend) then
    raise EArgumentNilException.Create('ABackend');
  if not Assigned(AReconnectTimerFactory) then
    raise EArgumentNilException.Create('AReconnectTimerFactory');
  FBackendName := 'unknown';
  BackendName := ABackend.GetBackendName;
  if BackendName <> '' then
    FBackendName := BackendName;
  InitCriticalSection(FBackendInfoLock);
  FBackendInfo := Default(TLazBleBackendInfo);
  FAvailability := lbaUnknown;
  FReconnectTimerFactory := AReconnectTimerFactory;
  FOperations := TList.Create;
  FClients := TList.Create;
  FManager := TBleCentralManager.Create(ABackend);
  FManager.OnScanResult := @ScanResult;
  FManager.OnScanCompleted := @ScanCompleted;
  FManager.OnAvailabilityResult := @AvailabilityResult;
  FManager.OnAvailabilityCompleted := @AvailabilityCompleted;
  FManager.OnStateChanged := @ManagerStateChanged;
end;

destructor TLazBle.Destroy;
var
  Entry: TBleSessionOperationEntry;
  Index: Integer;
begin
  if Assigned(FManager) then
  begin
    TBleCentralManagerAccess(FManager).DetachBackendEventsInternal;
    FManager.OnScanResult := nil;
    FManager.OnScanCompleted := nil;
    FManager.OnAvailabilityResult := nil;
    FManager.OnAvailabilityCompleted := nil;
    FManager.OnStateChanged := nil;
  end;
  for Index := FClients.Count - 1 downto 0 do
    TObject(FClients[Index]).Free;
  FClients.Free;
  for Index := FOperations.Count - 1 downto 0 do
  begin
    Entry := TBleSessionOperationEntry(FOperations[Index]);
    if Assigned(Entry.Instance.Session) then
      Entry.Instance.Session.OnStateChanged := nil;
    Entry.Operation.OnCompleted := nil;
    Entry.Operation := nil;
    Entry.Free;
  end;
  FManager.Free;
  FManager := nil;
  FOperations.Free;
  FActiveScan := nil;
  FActiveScanObject := nil;
  FActiveAvailability := nil;
  FActiveAvailabilityObject := nil;
  FShutdownOperation := nil;
  FShutdownOperationObject := nil;
  FReconnectTimerFactory := nil;
  DoneCriticalSection(FBackendInfoLock);
  inherited Destroy;
end;

function TLazBle.GetBackendInfo: TLazBleBackendInfo;
begin
  EnterCriticalSection(FBackendInfoLock);
  try
    Result := FBackendInfo;
  finally
    LeaveCriticalSection(FBackendInfoLock);
  end;
end;

function TLazBle.GetDiagnosticInfo: TLazBleDiagnosticInfo;
begin
  Result := Default(TLazBleDiagnosticInfo);
  Result.LazBleVersion := LazBleVersion;
  Result.BindingVersion := SimpleBlePascalVersion;
  Result.MinimumNativeVersion := SimpleBleMinimumNativeVersion;
  EnterCriticalSection(FBackendInfoLock);
  try
    Result.BackendName := FBackendName;
    if FBackendInfo.Name <> '' then
      Result.BackendName := FBackendInfo.Name;
    Result.NativeVersion := FBackendInfo.Version;
    Result.AdapterId := FBackendInfo.AdapterId;
    Result.WarningMessage := FBackendInfo.LoadWarning;
    Result.Availability := FAvailability;
    Result.ErrorMessage := FAvailabilityError;
  finally
    LeaveCriticalSection(FBackendInfoLock);
  end;
end;

procedure TLazBle.OperationCancelled(Sender: TObject);
var
  Entry: TBleSessionOperationEntry;
  Index: Integer;
  SessionOperation: TBleSessionOperation;
begin
  if Sender = FActiveScanObject then
  begin
    FManager.CancelScan;
    Exit;
  end;
  if Sender = FActiveAvailabilityObject then
  begin
    FManager.CancelAvailabilityCheck;
    Exit;
  end;
  if Sender is TBleSessionOperation then
  begin
    SessionOperation := TBleSessionOperation(Sender);
    if SessionOperation.Kind = lbsokConnect then
    begin
      if Assigned(SessionOperation.Session) then
        TBleGattSessionAccess(SessionOperation.Session).DisconnectInternal;
    end
    else
    begin
      TBleSessionOperationAccess(SessionOperation).Finish(lbopCancelled);
      for Index := FOperations.Count - 1 downto 0 do
      begin
        Entry := TBleSessionOperationEntry(FOperations[Index]);
        if Entry.Instance <> SessionOperation then
          Continue;
        FOperations.Delete(Index);
        Entry.Free;
        Break;
      end;
    end;
  end;
end;

procedure TLazBle.ScanResult(Sender: TObject; const ADeviceId,
  ADeviceName: string; const ARssi: SmallInt);
begin
  if Assigned(FActiveScan) and (FActiveScan.State = lbopPending) then
    TBleScanOperationAccess(FActiveScanObject).AddResult(ADeviceId,
      ADeviceName, ARssi);
end;

procedure TLazBle.ScanCompleted(Sender: TObject;
  const ASucceeded: Boolean; const AErrorCode: Integer;
  const AErrorMessage: string);
var
  Operation: IBleScanOperation;
  OperationObject: TBleScanOperation;
begin
  Operation := FActiveScan;
  OperationObject := FActiveScanObject;
  FActiveScan := nil;
  FActiveScanObject := nil;
  if not Assigned(Operation) then
    Exit;
  if Operation.CancelRequested then
    TBleScanOperationAccess(OperationObject).Finish(lbopCancelled)
  else if ASucceeded then
    TBleScanOperationAccess(OperationObject).Finish(lbopSucceeded)
  else
    TBleScanOperationAccess(OperationObject).Finish(lbopFailed, AErrorCode,
      AErrorMessage);
end;

procedure TLazBle.AvailabilityResult(Sender: TObject;
  const AAvailability: TBleAvailability;
  const ABackendInfo: TLazBleBackendInfo);
begin
  EnterCriticalSection(FBackendInfoLock);
  try
    FBackendInfo := ABackendInfo;
    FAvailability := AAvailability;
    FAvailabilityError := '';
  finally
    LeaveCriticalSection(FBackendInfoLock);
  end;
  if Assigned(FActiveAvailability) and
    (FActiveAvailability.State = lbopPending) then
    TBleAvailabilityOperationAccess(
      FActiveAvailabilityObject).StoreAvailability(AAvailability);
end;

procedure TLazBle.AvailabilityCompleted(Sender: TObject;
  const ASucceeded: Boolean; const AErrorCode: Integer;
  const AErrorMessage: string);
var
  Operation: IBleAvailabilityOperation;
  OperationObject: TBleAvailabilityOperation;
begin
  Operation := FActiveAvailability;
  OperationObject := FActiveAvailabilityObject;
  FActiveAvailability := nil;
  FActiveAvailabilityObject := nil;
  if not Assigned(Operation) then
    Exit;
  EnterCriticalSection(FBackendInfoLock);
  try
    if Operation.CancelRequested then
    begin
      FAvailability := lbaUnknown;
      FAvailabilityError := '';
    end
    else if ASucceeded and
      (Operation.Availability in [lbaAvailable, lbaUnavailable]) then
      FAvailabilityError := ''
    else
    begin
      FAvailability := lbaUnavailable;
      if ASucceeded then
        FAvailabilityError := 'BLE backend did not report availability'
      else
        FAvailabilityError := AErrorMessage;
    end;
  finally
    LeaveCriticalSection(FBackendInfoLock);
  end;
  if Operation.CancelRequested then
    TBleAvailabilityOperationAccess(OperationObject).Finish(lbopCancelled)
  else if ASucceeded and
    (Operation.Availability in [lbaAvailable, lbaUnavailable]) then
    TBleAvailabilityOperationAccess(OperationObject).Finish(lbopSucceeded)
  else if ASucceeded then
    TBleAvailabilityOperationAccess(OperationObject).Finish(lbopFailed, 0,
      'BLE backend did not report availability')
  else
    TBleAvailabilityOperationAccess(OperationObject).Finish(lbopFailed,
      AErrorCode, AErrorMessage);
end;

procedure TLazBle.CompleteSessionOperations(
  const ASession: TBleGattSession; const AState: TLazBleSessionState);
var
  Entry: TBleSessionOperationEntry;
  Index: Integer;
  Operation: TBleSessionOperation;
begin
  for Index := FOperations.Count - 1 downto 0 do
    begin
      Entry := TBleSessionOperationEntry(FOperations[Index]);
      Operation := Entry.Instance;
      if (Operation.Session <> ASession) or
        (Operation.State <> lbopPending) then
        Continue;
      case Operation.Kind of
        lbsokConnect:
          if AState = lbssConnected then
            TBleSessionOperationAccess(Operation).Finish(lbopSucceeded)
          else if AState in [lbssDisconnected, lbssError] then
          begin
            if Operation.CancelRequested then
              TBleSessionOperationAccess(Operation).Finish(lbopCancelled)
            else
              TBleSessionOperationAccess(Operation).Finish(lbopFailed, 0,
                'Could not connect and discover GATT services');
          end;
        lbsokDisconnect:
          if AState = lbssDisconnected then
            TBleSessionOperationAccess(Operation).Finish(lbopSucceeded)
          else if AState = lbssError then
            TBleSessionOperationAccess(Operation).Finish(lbopFailed, 0,
                'Could not disconnect BLE session');
      end;
      if Operation.State <> lbopPending then
      begin
        Operation.Session.OnStateChanged := nil;
        FOperations.Delete(Index);
        Entry.Free;
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
    TBleOperationAccess(FShutdownOperationObject).Finish(lbopSucceeded);
end;

procedure TLazBle.CancelPendingOperations;
var
  Entry: TBleSessionOperationEntry;
  Index: Integer;
  Operations: array of IBleOperation;
begin
  Operations := nil;
  if Assigned(FActiveScan) and (FActiveScan.State = lbopPending) then
    FActiveScan.Cancel;
  if Assigned(FActiveAvailability) and
    (FActiveAvailability.State = lbopPending) then
    FActiveAvailability.Cancel;
  for Index := 0 to FClients.Count - 1 do
    TBleClientAccess(FClients[Index]).CancelForShutdown;
  SetLength(Operations, FOperations.Count);
  for Index := 0 to High(Operations) do
  begin
    Entry := TBleSessionOperationEntry(FOperations[Index]);
    Operations[Index] := Entry.Operation;
  end;
  for Index := 0 to High(Operations) do
    if Operations[Index].State = lbopPending then
      Operations[Index].Cancel;
end;

function TLazBle.CheckAvailabilityAsync(const AAdapterId: string):
  IBleAvailabilityOperation;
var
  Operation: TBleAvailabilityOperationAccess;
begin
  if Assigned(FActiveAvailability) and
    (FActiveAvailability.State = lbopPending) then
    Exit(FActiveAvailability);
  EnterCriticalSection(FBackendInfoLock);
  try
    FBackendInfo := Default(TLazBleBackendInfo);
    FAvailability := lbaChecking;
    FAvailabilityError := '';
  finally
    LeaveCriticalSection(FBackendInfoLock);
  end;
  Operation := TBleAvailabilityOperationAccess.CreateInternal(
    @OperationCancelled);
  Result := Operation;
  FActiveAvailability := Result;
  FActiveAvailabilityObject := Operation;
  if FManager.CheckAvailability(AAdapterId) = InvalidBleOperationId then
  begin
    FActiveAvailability := nil;
    FActiveAvailabilityObject := nil;
    EnterCriticalSection(FBackendInfoLock);
    try
      FAvailability := lbaUnavailable;
      FAvailabilityError := 'Could not start BLE availability check';
    finally
      LeaveCriticalSection(FBackendInfoLock);
    end;
    Operation.Finish(lbopFailed, 0,
      'Could not start BLE availability check');
  end;
end;

function TLazBle.ScanAsync(const AAdapterId: string;
  const ATimeoutMs: Cardinal): IBleScanOperation;
var
  Operation: TBleScanOperationAccess;
begin
  if Assigned(FActiveScan) and (FActiveScan.State = lbopPending) then
    Exit(FActiveScan);
  Operation := TBleScanOperationAccess.CreateInternal(@OperationCancelled);
  Result := Operation;
  FActiveScan := Result;
  FActiveScanObject := Operation;
  if FManager.StartScan(AAdapterId, ATimeoutMs) = InvalidBleOperationId then
  begin
    FActiveScan := nil;
    FActiveScanObject := nil;
    Operation.Finish(lbopFailed, 0,
      'Could not start BLE scan');
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
    raise EInvalidOperation.Create(
      'Cannot create a BLE client after shutdown has started');
  Result := TBleClientAccess.CreateInternal(Session, @ConnectSessionAsync,
    @DisconnectSessionAsync, FReconnectTimerFactory.CreateTimer);
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
  if not (AClient.State in [lbcstDisconnected, lbcstError]) then
    raise EInvalidOperation.Create(
      'BLE client must be disconnected or in error before it can be removed');
  FClients.Delete(Index);
  AClient.Free;
end;

function TLazBle.ConnectSessionAsync(
  const ADeviceId: string): IBleOperation;
var
  Entry: TBleSessionOperationEntry;
  Operation: TBleSessionOperation;
  Session: TBleGattSession;
begin
  Session := FManager.CreateSession(ADeviceId);
  Operation := TBleSessionOperation.Create(Session, lbsokConnect,
    @OperationCancelled);
  Result := Operation;
  Entry := TBleSessionOperationEntry.Create;
  Entry.Instance := Operation;
  Entry.Operation := Result;
  FOperations.Add(Entry);
  if not Assigned(Session) then
  begin
    TBleSessionOperationAccess(Operation).Finish(lbopFailed, 0,
      'Could not create BLE session');
    FOperations.Remove(Entry);
    Entry.Free;
    Exit;
  end;
  Session.OnStateChanged := @SessionStateChanged;
  if Session.State = lbssConnected then
    TBleSessionOperationAccess(Operation).Finish(lbopSucceeded)
  else if TBleGattSessionAccess(Session).ConnectInternal =
    InvalidBleOperationId then
    TBleSessionOperationAccess(Operation).Finish(lbopFailed, 0,
      'Could not start BLE connection');
  if Operation.State <> lbopPending then
  begin
    Session.OnStateChanged := nil;
    FOperations.Remove(Entry);
    Entry.Free;
  end;
end;

function TLazBle.DisconnectSessionAsync(const ASession: TBleGattSession):
  IBleOperation;
var
  Entry: TBleSessionOperationEntry;
  Operation: TBleSessionOperation;
begin
  Operation := TBleSessionOperation.Create(ASession, lbsokDisconnect,
    @OperationCancelled);
  Result := Operation;
  Entry := TBleSessionOperationEntry.Create;
  Entry.Instance := Operation;
  Entry.Operation := Result;
  FOperations.Add(Entry);
  if not Assigned(ASession) then
  begin
    TBleSessionOperationAccess(Operation).Finish(lbopFailed, 0,
      'BLE session is not assigned');
    FOperations.Remove(Entry);
    Entry.Free;
    Exit;
  end;
  ASession.OnStateChanged := @SessionStateChanged;
  if ASession.State = lbssDisconnected then
    TBleSessionOperationAccess(Operation).Finish(lbopSucceeded)
  else if TBleGattSessionAccess(ASession).DisconnectInternal =
    InvalidBleOperationId then
    TBleSessionOperationAccess(Operation).Finish(lbopFailed, 0,
      'Could not start BLE disconnect');
  if Operation.State <> lbopPending then
  begin
    ASession.OnStateChanged := nil;
    FOperations.Remove(Entry);
    Entry.Free;
  end;
end;

function TLazBle.ShutdownAsync: IBleOperation;
var
  Operation: TBleOperationAccess;
begin
  if Assigned(FShutdownOperation) then
    Exit(FShutdownOperation);
  CancelPendingOperations;
  Operation := TBleOperationAccess.CreateInternal(nil);
  FShutdownOperation := Operation;
  FShutdownOperationObject := Operation;
  if FManager.State = lbcsShutdown then
    Operation.Finish(lbopSucceeded)
  else if FManager.BeginShutdown = InvalidBleOperationId then
    Operation.Finish(lbopFailed, 0,
      'Could not start BLE shutdown');
  Result := FShutdownOperation;
end;

end.
