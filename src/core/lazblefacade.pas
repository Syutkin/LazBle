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

  TLazBle = class
  private
    FManager: TBleCentralManager;
    FOperations: TList;
    FClients: TList;
    FActiveScan: IBleScanOperation;
    FActiveScanObject: TBleScanOperation;
    FShutdownOperation: IBleOperation;
    FShutdownOperationObject: TBleOperation;
    FReconnectTimerFactory: ILazBleReconnectTimerFactory;
    procedure OperationCancelled(Sender: TObject);
    procedure ScanResult(Sender: TObject; const ADeviceId,
      ADeviceName: string; const ARssi: SmallInt);
    procedure ScanCompleted(Sender: TObject; const ASucceeded: Boolean;
      const AErrorCode: Integer; const AErrorMessage: string);
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
    function ScanAsync(const AAdapterId: string;
      const ATimeoutMs: Cardinal): IBleScanOperation;
    function CreateClient(const ADeviceId: string): TBleClient;
    function FindClient(const ADeviceId: string): TBleClient;
    procedure RemoveClient(const AClient: TBleClient);
    function ShutdownAsync: IBleOperation;
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
begin
  inherited Create;
  if not Assigned(ABackend) then
    raise EArgumentNilException.Create('ABackend');
  if not Assigned(AReconnectTimerFactory) then
    raise EArgumentNilException.Create('AReconnectTimerFactory');
  FReconnectTimerFactory := AReconnectTimerFactory;
  FOperations := TList.Create;
  FClients := TList.Create;
  FManager := TBleCentralManager.Create(ABackend);
  FManager.OnScanResult := @ScanResult;
  FManager.OnScanCompleted := @ScanCompleted;
  FManager.OnStateChanged := @ManagerStateChanged;
end;

destructor TLazBle.Destroy;
var
  Entry: TBleSessionOperationEntry;
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
  FShutdownOperation := nil;
  FShutdownOperationObject := nil;
  FReconnectTimerFactory := nil;
  inherited Destroy;
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
  OperationCount: Integer;
begin
  for Index := 0 to FClients.Count - 1 do
    TBleClientAccess(FClients[Index]).CancelForShutdown;
  OperationCount := FOperations.Count;
  for Index := 0 to OperationCount - 1 do
  begin
    Entry := TBleSessionOperationEntry(FOperations[Index]);
    if Entry.Operation.State = lbopPending then
      Entry.Operation.Cancel;
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
  if AClient.State <> lbcstDisconnected then
    raise EInvalidOperation.Create(
      'BLE client must be disconnected before it can be removed');
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
