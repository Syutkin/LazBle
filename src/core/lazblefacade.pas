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
    class function GetLibraryPath: string; static;
    class procedure SetLibraryPath(const APath: string); static;
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
    procedure ManagerStateChanged(Sender: TObject;
      const AState: TLazBleCentralState);
    procedure CancelPendingOperations;
    function ConnectSessionAsync(const ADeviceId: string):
      IBleOperation;
    function DisconnectSessionAsync(const ASession: TBleGattSession):
      IBleOperation;
  protected
    constructor Create(const ABackend: ILazBleBackend;
      const AReconnectTimerFactory: ILazBleReconnectTimerFactory); overload;
  public
    { Process-wide SimpleDelphiBLE file/directory override. Set before the first
      native call; empty uses the upstream executable/system search. }
    class property LibraryPath: string read GetLibraryPath write SetLibraryPath;
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
  LazBleSimpleBleBackend, SimpleDelphiBLE;

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
    function ConnectInternal: IBleOperation;
    function DisconnectInternal: IBleOperation;
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

function TBleGattSessionAccess.ConnectInternal: IBleOperation;
begin
  LazBleRequireMainThread;
  Result := BeginConnect;
end;

function TBleGattSessionAccess.DisconnectInternal: IBleOperation;
begin
  LazBleRequireMainThread;
  Result := BeginDisconnect;
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
  FManager.Free;
  FManager := nil;
  FActiveScan := nil;
  FActiveScanObject := nil;
  FActiveAvailability := nil;
  FActiveAvailabilityObject := nil;
  FShutdownOperation := nil;
  FShutdownOperationObject := nil;
  FReconnectTimerFactory := nil;
  inherited Destroy;
end;

class function TLazBle.GetLibraryPath: string;
begin
  LazBleRequireMainThread;
  Result := UTF8Encode(TSimpleDelphiBLE.LibraryPath);
end;

class procedure TLazBle.SetLibraryPath(const APath: string);
begin
  LazBleRequireMainThread;
  TSimpleDelphiBLE.LibraryPath := UTF8Decode(APath);
end;

function TLazBle.GetDiagnosticInfo: TLazBleDiagnosticInfo;
begin
  LazBleRequireMainThread;
  Result := FDiagnosticInfo;
end;

procedure TLazBle.OperationCancelled(Sender: TObject);
begin
  LazBleRequireMainThread;
  if Sender = FActiveScanObject then FManager.CancelScan
  else if Sender = FActiveAvailabilityObject then FManager.CancelAvailabilityCheck;
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

procedure TLazBle.CancelPendingOperations;
var Index: Integer;
begin
  LazBleRequireMainThread;
  if Assigned(FActiveScan) and (FActiveScan.State = lbopPending) then FActiveScan.Cancel;
  if Assigned(FActiveAvailability) and (FActiveAvailability.State = lbopPending) then
    FActiveAvailability.Cancel;
  for Index := 0 to FClients.Count - 1 do
    TBleClientAccess(FClients[Index]).CancelForShutdown;
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

function TLazBle.ConnectSessionAsync(const ADeviceId: string): IBleOperation;
var Session: TBleGattSession; Operation: TBleOperationAccess;
begin
  LazBleRequireMainThread;
  Session := FManager.CreateSession(ADeviceId);
  if Session <> nil then Exit(TBleGattSessionAccess(Session).ConnectInternal);
  Operation := TBleOperationAccess.CreateInternal(nil);
  Result := Operation;
  Operation.Finish(lbopFailed, LazBleErrorInvalidState, 'Could not create BLE session');
end;

function TLazBle.DisconnectSessionAsync(const ASession: TBleGattSession): IBleOperation;
var Operation: TBleOperationAccess;
begin
  LazBleRequireMainThread;
  if ASession <> nil then Exit(TBleGattSessionAccess(ASession).DisconnectInternal);
  Operation := TBleOperationAccess.CreateInternal(nil);
  Result := Operation;
  Operation.Finish(lbopFailed, LazBleErrorInvalidState, 'BLE session is not assigned');
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
