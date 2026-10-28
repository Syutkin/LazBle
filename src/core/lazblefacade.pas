unit LazBleFacade;

{$mode objfpc}{$H+}{$J-}

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

  { Main-thread, FPC-only facade. The default constructor selects SimpleBLE;
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
    FDiagnosticInfo: TLazBleDiagnosticInfo;
    FBackendName: string;
    function GetDiagnosticInfo: TLazBleDiagnosticInfo;
    procedure OperationCancelled(Sender: TObject);
    procedure ScanResult(Sender: TObject; const ADeviceId,
      ADeviceName: string; const ARssi: SmallInt);
    procedure ScanCompleted(Sender: TObject; const AOutcome: TLazBleBackendEventKind;
      const AErrorCode: Integer; const AErrorMessage: string);
    procedure AvailabilityResult(Sender: TObject;
      const AEvent: TLazBleBackendEvent);
    procedure AvailabilityCompleted(Sender: TObject;
      const AOutcome: TLazBleBackendEventKind; const AErrorCode: Integer;
      const AErrorMessage: string);
    procedure SessionStateChanged(Sender: TObject;
      const AState: TLazBleSessionState);
    procedure ManagerStateChanged(Sender: TObject;
      const AState: TLazBleCentralState);
    procedure CancelPendingOperations;
    procedure RemoveSessionOperation(const AOperation: TBleSessionOperation);
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
    { Static package information; no instance or BLE work is required.
      Keep Version aligned with core/LCL/design package metadata. }
    const Info: TLazBleInfo = (
      Name: 'LazBle';
      Version: '2.0.0';
      About: 'Asynchronous BLE and GATT client library for Free Pascal'
    );
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
      Example: Diagnostic := Ble.DiagnosticInfo; after CheckAvailabilityAsync
      completes, Diagnostic.NativeVersion is the reported native version or ''. }
    property DiagnosticInfo: TLazBleDiagnosticInfo read GetDiagnosticInfo;
  end;

implementation

uses
  LazBleSimpleBleBackend;

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
    procedure CancelConnectInternal;
    procedure CancelDisconnectInternal;
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
  LazBleRequireMainThread;
  DetachBackendEvents;
end;

function TBleGattSessionAccess.ConnectInternal: TBleOperationId;
begin
  LazBleRequireMainThread;
  Result := Connect;
end;

function TBleGattSessionAccess.DisconnectInternal: TBleOperationId;
begin
  LazBleRequireMainThread;
  Result := Disconnect;
end;

procedure TBleGattSessionAccess.CancelConnectInternal;
begin CancelConnect; end;
procedure TBleGattSessionAccess.CancelDisconnectInternal;
begin CancelDisconnect; end;

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
  LazBleRequireMainThread;
  Complete(AState, AErrorCode, AErrorMessage);
end;

procedure TBleAvailabilityOperationAccess.StoreAvailability(
  const AAvailability: TBleAvailability);
begin
  LazBleRequireMainThread;
  SetAvailability(AAvailability);
end;

procedure TBleOperationAccess.Finish(const AState: TLazBleOperationState;
  const AErrorCode: Integer; const AErrorMessage: string);
begin
  LazBleRequireMainThread;
  Complete(AState, AErrorCode, AErrorMessage);
end;

procedure TBleScanOperationAccess.AddResult(const ADeviceId,
  ADeviceName: string; const ARssi: SmallInt);
begin
  LazBleRequireMainThread;
  AddOrUpdateResult(ADeviceId, ADeviceName, ARssi);
end;

procedure TBleScanOperationAccess.Finish(const AState: TLazBleOperationState;
  const AErrorCode: Integer; const AErrorMessage: string);
begin
  LazBleRequireMainThread;
  Complete(AState, AErrorCode, AErrorMessage);
end;

procedure TBleSessionOperationAccess.Finish(
  const AState: TLazBleOperationState; const AErrorCode: Integer;
  const AErrorMessage: string);
begin
  LazBleRequireMainThread;
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
  LazBleRequireMainThread;
  if not Assigned(ABackend) then
    raise EArgumentNilException.Create('ABackend');
  if not Assigned(AReconnectTimerFactory) then
    raise EArgumentNilException.Create('AReconnectTimerFactory');
  FBackendName := 'unknown';
  BackendName := ABackend.GetBackendName;
  if BackendName <> '' then
    FBackendName := BackendName;
  FDiagnosticInfo := Default(TLazBleDiagnosticInfo);
  FDiagnosticInfo.BackendName := FBackendName;
  FDiagnosticInfo.Availability := lbaUnknown;
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
  if Assigned(FActiveScan) then
  begin
    FActiveScan.OnCompleted := nil;
    FActiveScan.OnResult := nil;
    TBleScanOperationAccess(FActiveScanObject).Finish(lbopCancelled);
  end;
  if Assigned(FActiveAvailability) then
  begin
    FActiveAvailability.OnCompleted := nil;
    TBleAvailabilityOperationAccess(FActiveAvailabilityObject).Finish(lbopCancelled);
  end;
  if Assigned(FShutdownOperation) then
  begin
    FShutdownOperation.OnCompleted := nil;
    TBleOperationAccess(FShutdownOperationObject).Finish(lbopCancelled);
  end;
  if FClients <> nil then
    for Index := FClients.Count - 1 downto 0 do TObject(FClients[Index]).Free;
  FClients.Free;
  if FOperations <> nil then
    for Index := FOperations.Count - 1 downto 0 do
    begin
      Entry := TBleSessionOperationEntry(FOperations[Index]);
      if Assigned(Entry.Instance.Session) then Entry.Instance.Session.OnStateChanged := nil;
      Entry.Operation.OnCompleted := nil;
      TBleSessionOperationAccess(Entry.Instance).Finish(lbopCancelled);
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
  inherited Destroy;
end;

function TLazBle.GetDiagnosticInfo: TLazBleDiagnosticInfo;
begin
  LazBleRequireMainThread;
  Result := FDiagnosticInfo;
end;

procedure TLazBle.OperationCancelled(Sender: TObject);
var Operation: TBleSessionOperation;
begin
  LazBleRequireMainThread;
  if Sender = FActiveScanObject then FManager.CancelScan
  else if Sender = FActiveAvailabilityObject then FManager.CancelAvailabilityCheck
  else if Sender is TBleSessionOperation then
  begin
    Operation := TBleSessionOperation(Sender);
    if Operation.Session = nil then Exit;
    if Operation.Kind = lbsokConnect then
      TBleGattSessionAccess(Operation.Session).CancelConnectInternal
    else TBleGattSessionAccess(Operation.Session).CancelDisconnectInternal;
  end;
end;

procedure TLazBle.ScanResult(Sender: TObject; const ADeviceId,
  ADeviceName: string; const ARssi: SmallInt);
begin
  LazBleRequireMainThread;
  if Assigned(FActiveScan) and (FActiveScan.State = lbopPending) then
    TBleScanOperationAccess(FActiveScanObject).AddResult(ADeviceId,
      ADeviceName, ARssi);
end;

procedure TLazBle.ScanCompleted(Sender: TObject;
  const AOutcome: TLazBleBackendEventKind; const AErrorCode: Integer;
  const AErrorMessage: string);
var
  Operation: IBleScanOperation;
  OperationObject: TBleScanOperation;
begin
  LazBleRequireMainThread;
  Operation := FActiveScan;
  OperationObject := FActiveScanObject;
  FActiveScan := nil;
  FActiveScanObject := nil;
  if not Assigned(Operation) then
    Exit;
  if AOutcome = lbekOperationCancelled then
    TBleScanOperationAccess(OperationObject).Finish(lbopCancelled)
  else if AOutcome = lbekOperationSucceeded then
    TBleScanOperationAccess(OperationObject).Finish(lbopSucceeded)
  else
    TBleScanOperationAccess(OperationObject).Finish(lbopFailed, AErrorCode,
      AErrorMessage);
end;

procedure TLazBle.AvailabilityResult(Sender: TObject;
  const AEvent: TLazBleBackendEvent);
var
  Availability: TBleAvailability;
begin
  LazBleRequireMainThread;
  if AEvent.Available then
    Availability := lbaAvailable
  else
    Availability := lbaUnavailable;
  if Assigned(FActiveAvailability) and
    (FActiveAvailability.State = lbopPending) then
    TBleAvailabilityOperationAccess(
      FActiveAvailabilityObject).StoreAvailability(Availability);
  FDiagnosticInfo.BackendName := FBackendName;
  if AEvent.BackendName <> '' then
    FDiagnosticInfo.BackendName := AEvent.BackendName;
  FDiagnosticInfo.NativeVersion := AEvent.BackendVersion;
  FDiagnosticInfo.AdapterId := AEvent.AdapterId;
  FDiagnosticInfo.AvailabilityErrorMessage := '';
end;

procedure TLazBle.AvailabilityCompleted(Sender: TObject;
  const AOutcome: TLazBleBackendEventKind; const AErrorCode: Integer;
  const AErrorMessage: string);
var
  Operation: IBleAvailabilityOperation;
  OperationObject: TBleAvailabilityOperation;
begin
  LazBleRequireMainThread;
  Operation := FActiveAvailability;
  OperationObject := FActiveAvailabilityObject;
  FActiveAvailability := nil;
  FActiveAvailabilityObject := nil;
  if not Assigned(Operation) then
    Exit;
  if AOutcome = lbekOperationCancelled then
  begin
    FDiagnosticInfo.Availability := lbaUnknown;
    FDiagnosticInfo.AvailabilityErrorMessage := '';
  end
  else if (AOutcome = lbekOperationSucceeded) and
    (Operation.Availability in [lbaAvailable, lbaUnavailable]) then
  begin
    FDiagnosticInfo.Availability := Operation.Availability;
    FDiagnosticInfo.AvailabilityErrorMessage := '';
  end
  else
  begin
    FDiagnosticInfo.Availability := lbaUnavailable;
    if AOutcome = lbekOperationSucceeded then
      FDiagnosticInfo.AvailabilityErrorMessage := 'BLE backend did not report availability'
    else
      FDiagnosticInfo.AvailabilityErrorMessage := AErrorMessage;
  end;
  if Assigned(FShutdownOperation) then
    FDiagnosticInfo.Availability := lbaUnavailable;
  if AOutcome = lbekOperationCancelled then
    TBleAvailabilityOperationAccess(OperationObject).Finish(lbopCancelled)
  else if (AOutcome = lbekOperationSucceeded) and
    (Operation.Availability in [lbaAvailable, lbaUnavailable]) then
    TBleAvailabilityOperationAccess(OperationObject).Finish(lbopSucceeded)
  else if AOutcome = lbekOperationSucceeded then
    TBleAvailabilityOperationAccess(OperationObject).Finish(lbopFailed, 0,
      'BLE backend did not report availability')
  else
    TBleAvailabilityOperationAccess(OperationObject).Finish(lbopFailed,
      AErrorCode, AErrorMessage);
end;

procedure TLazBle.CompleteSessionOperations(const ASession: TBleGattSession;
  const AState: TLazBleSessionState);
var
  Entry: TBleSessionOperationEntry;
  I, J: Integer;
  Operations: array of IBleOperation;
  Instances: array of TBleSessionOperation;
  Operation: TBleSessionOperation;
  Outcome: TLazBleOperationState;
  Code: Integer;
  Text: string;
  Cancelled, Failed, ShuttingDown: Boolean;
begin
  LazBleRequireMainThread;
  { Snapshot interfaces retain operations across callbacks that add/finish
    other requests. Remove an entry BEFORE notifying its user. Session keeps
    its facade handler for its whole lifetime, including reentrant requests. }
  Code := ASession.ErrorCode;
  Text := ASession.ErrorMessage;
  Cancelled := ASession.LastOperationCancelled;
  Failed := ASession.LastOperationFailed;
  ShuttingDown := FManager.State = lbcsShuttingDown;
  SetLength(Operations, FOperations.Count);
  SetLength(Instances, FOperations.Count);
  for I := 0 to FOperations.Count - 1 do
  begin
    Entry := TBleSessionOperationEntry(FOperations[I]);
    Operations[I] := Entry.Operation; Instances[I] := Entry.Instance;
  end;
  for I := 0 to High(Instances) do
  begin
    Operation := Instances[I];
    if (Operation.Session <> ASession) or (Operation.State <> lbopPending) then Continue;
    Outcome := lbopPending;
    case Operation.Kind of
      lbsokConnect:
        if AState = lbssConnected then Outcome := lbopSucceeded
        else if AState in [lbssDisconnected, lbssError] then
          if Cancelled or ShuttingDown then Outcome := lbopCancelled
          else Outcome := lbopFailed;
      lbsokDisconnect:
        if Cancelled then Outcome := lbopCancelled
        else if AState = lbssDisconnected then Outcome := lbopSucceeded
        else if AState = lbssError then Outcome := lbopFailed;
    end;
    if Outcome = lbopPending then Continue;
    for J := FOperations.Count - 1 downto 0 do
    begin
      Entry := TBleSessionOperationEntry(FOperations[J]);
      if Entry.Instance <> Operation then Continue;
      FOperations.Delete(J); Entry.Free; Break;
    end;
    if (Outcome = lbopFailed) and Failed then
      TBleSessionOperationAccess(Operation).Finish(Outcome, Code, Text)
    else if Outcome = lbopFailed then
      TBleSessionOperationAccess(Operation).Finish(Outcome, LazBleErrorDeviceDisconnected,
        'BLE session ended before the operation completed')
    else TBleSessionOperationAccess(Operation).Finish(Outcome);
  end;
end;

procedure TLazBle.SessionStateChanged(Sender: TObject;
  const AState: TLazBleSessionState);
begin
  LazBleRequireMainThread;
  if Sender is TBleGattSession then
    CompleteSessionOperations(TBleGattSession(Sender), AState);
end;

procedure TLazBle.ManagerStateChanged(Sender: TObject;
  const AState: TLazBleCentralState);
begin
  LazBleRequireMainThread;
  if Assigned(FShutdownOperation) and (AState = lbcsShutdown) then
    if FManager.ShutdownFailed then
      TBleOperationAccess(FShutdownOperationObject).Finish(lbopFailed,
        FManager.ShutdownErrorCode, FManager.ShutdownErrorMessage)
    else TBleOperationAccess(FShutdownOperationObject).Finish(lbopSucceeded);
end;

procedure TLazBle.RemoveSessionOperation(const AOperation: TBleSessionOperation);
var I: Integer; Entry: TBleSessionOperationEntry;
begin
  for I := FOperations.Count - 1 downto 0 do
  begin
    Entry := TBleSessionOperationEntry(FOperations[I]);
    if Entry.Instance <> AOperation then Continue;
    FOperations.Delete(I); Entry.Free; Exit;
  end;
end;

procedure TLazBle.CancelPendingOperations;
var
  Entry: TBleSessionOperationEntry;
  Index: Integer;
  Operations: array of IBleOperation;
begin
  LazBleRequireMainThread;
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
  LazBleRequireMainThread;
  if Assigned(FShutdownOperation) then
  begin
    Operation := TBleAvailabilityOperationAccess.CreateInternal(nil);
    Result := Operation;
    Operation.Finish(lbopFailed, LazBleErrorInvalidState, 'LazBle is shut down');
    Exit;
  end;
  if Assigned(FActiveAvailability) and
    (FActiveAvailability.State = lbopPending) then
    Exit(FActiveAvailability);
  FDiagnosticInfo.BackendName := FBackendName;
  FDiagnosticInfo.NativeVersion := '';
  FDiagnosticInfo.AdapterId := '';
  FDiagnosticInfo.Availability := lbaChecking;
  FDiagnosticInfo.AvailabilityErrorMessage := '';
  Operation := TBleAvailabilityOperationAccess.CreateInternal(
    @OperationCancelled);
  Result := Operation;
  FActiveAvailability := Result;
  FActiveAvailabilityObject := Operation;
  if FManager.CheckAvailability(AAdapterId) = InvalidBleOperationId then
  begin
    FActiveAvailability := nil;
    FActiveAvailabilityObject := nil;
    FDiagnosticInfo.Availability := lbaUnavailable;
    FDiagnosticInfo.AvailabilityErrorMessage := 'Could not start BLE availability check';
    Operation.Finish(lbopFailed, 0,
      'Could not start BLE availability check');
  end;
end;

function TLazBle.ScanAsync(const AAdapterId: string;
  const ATimeoutMs: Cardinal): IBleScanOperation;
var
  Operation: TBleScanOperationAccess;
begin
  LazBleRequireMainThread;
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
  LazBleRequireMainThread;
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
  LazBleRequireMainThread;
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
  LazBleRequireMainThread;
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
  LazBleRequireMainThread;
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
    RemoveSessionOperation(Operation);
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
    RemoveSessionOperation(Operation);
  end;
end;

function TLazBle.DisconnectSessionAsync(const ASession: TBleGattSession):
  IBleOperation;
var
  Entry: TBleSessionOperationEntry;
  Operation: TBleSessionOperation;
begin
  LazBleRequireMainThread;
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
    RemoveSessionOperation(Operation);
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
    RemoveSessionOperation(Operation);
  end;
end;

function TLazBle.ShutdownAsync: IBleOperation;
var
  Operation: TBleOperationAccess;
begin
  LazBleRequireMainThread;
  if Assigned(FShutdownOperation) then
    Exit(FShutdownOperation);
  Operation := TBleOperationAccess.CreateInternal(nil);
  FShutdownOperation := Operation;
  FShutdownOperationObject := Operation;
  FDiagnosticInfo.Availability := lbaUnavailable;
  CancelPendingOperations;
  if FManager.State = lbcsShutdown then
    Operation.Finish(lbopSucceeded)
  else if FManager.BeginShutdown = InvalidBleOperationId then
    Operation.Finish(lbopFailed, 0,
      'Could not start BLE shutdown');
  Result := FShutdownOperation;
end;

end.
