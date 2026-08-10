unit LazBleFacade;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  LazBleTypes,
  LazBleBackend,
  LazBleGattSession,
  LazBleCentralManager,
  LazBleClient,
  LazBleReconnect;

type
  ELazBleDuplicateClient = class(Exception);

  TLazBle = class
  private
    FManager: TBleCentralManager;
    FOperations: TList;
    FClients: TList;
    FActiveScan: TBleScanOperation;
    FShutdownOperation: TBleOperation;
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
      TBleSessionOperation;
    function DisconnectSessionAsync(const ASession: TBleGattSession):
      TBleSessionOperation;
  public
    constructor Create; overload;
    constructor Create(const ABackend: ILazBleBackend); overload;
    constructor Create(const ABackend: ILazBleBackend;
      const AReconnectTimerFactory: ILazBleReconnectTimerFactory); overload;
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
  TBleClientAccess = class(TBleClient);

  TBleOperationAccess = class(TBleOperation)
  public
    procedure Finish(const AState: TLazBleOperationState;
      const AErrorCode: Integer = 0; const AErrorMessage: string = '');
  end;

  TBleScanOperationAccess = class(TBleScanOperation)
  public
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
  FReconnectTimerFactory := nil;
  inherited Destroy;
end;

procedure TLazBle.OperationCancelled(Sender: TObject);
var
  SessionOperation: TBleSessionOperation;
begin
  if Sender = FActiveScan then
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
        SessionOperation.Session.Disconnect;
    end
    else
      TBleSessionOperationAccess(SessionOperation).Finish(lbopCancelled);
  end;
end;

procedure TLazBle.ScanResult(Sender: TObject; const ADeviceId,
  ADeviceName: string; const ARssi: SmallInt);
begin
  if Assigned(FActiveScan) and (FActiveScan.State = lbopPending) then
    TBleScanOperationAccess(FActiveScan).AddResult(ADeviceId, ADeviceName,
      ARssi);
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
    TBleScanOperationAccess(Operation).Finish(lbopCancelled)
  else if ASucceeded then
    TBleScanOperationAccess(Operation).Finish(lbopSucceeded)
  else
    TBleScanOperationAccess(Operation).Finish(lbopFailed, AErrorCode,
      AErrorMessage);
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
    TBleOperationAccess(FShutdownOperation).Finish(lbopSucceeded);
end;

procedure TLazBle.CancelPendingOperations;
var
  Index: Integer;
  Operation: TBleOperation;
  OperationCount: Integer;
begin
  for Index := 0 to FClients.Count - 1 do
    TBleClientAccess(FClients[Index]).CancelForShutdown;
  OperationCount := FOperations.Count;
  for Index := 0 to OperationCount - 1 do
    if TObject(FOperations[Index]) is TBleOperation then
    begin
      Operation := TBleOperation(FOperations[Index]);
      if Operation.State = lbopPending then
        Operation.Cancel;
    end;
end;

function TLazBle.ScanAsync(const AAdapterId: string;
  const ATimeoutMs: Cardinal): TBleScanOperation;
begin
  if Assigned(FActiveScan) and (FActiveScan.State = lbopPending) then
    Exit(FActiveScan);
  Result := TBleScanOperation.Create(@OperationCancelled);
  FOperations.Add(Result);
  FActiveScan := Result;
  if FManager.StartScan(AAdapterId, ATimeoutMs) = InvalidBleOperationId then
  begin
    FActiveScan := nil;
    TBleScanOperationAccess(Result).Finish(lbopFailed, 0,
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
    Exit(nil);
  Result := TBleClient.Create(Session, @ConnectSessionAsync,
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
    TBleSessionOperationAccess(Result).Finish(lbopFailed, 0,
      'Could not create BLE session');
    Exit;
  end;
  Session.OnStateChanged := @SessionStateChanged;
  if Session.State = lbssConnected then
    TBleSessionOperationAccess(Result).Finish(lbopSucceeded)
  else if Session.Connect = InvalidBleOperationId then
    TBleSessionOperationAccess(Result).Finish(lbopFailed, 0,
      'Could not start BLE connection');
end;

function TLazBle.DisconnectSessionAsync(const ASession: TBleGattSession):
  TBleSessionOperation;
begin
  Result := TBleSessionOperation.Create(ASession, lbsokDisconnect,
    @OperationCancelled);
  FOperations.Add(Result);
  if not Assigned(ASession) then
  begin
    TBleSessionOperationAccess(Result).Finish(lbopFailed, 0,
      'BLE session is not assigned');
    Exit;
  end;
  ASession.OnStateChanged := @SessionStateChanged;
  if ASession.State = lbssDisconnected then
    TBleSessionOperationAccess(Result).Finish(lbopSucceeded)
  else if ASession.Disconnect = InvalidBleOperationId then
    TBleSessionOperationAccess(Result).Finish(lbopFailed, 0,
      'Could not start BLE disconnect');
end;

function TLazBle.ShutdownAsync: TBleOperation;
begin
  if Assigned(FShutdownOperation) then
    Exit(FShutdownOperation);
  CancelPendingOperations;
  FShutdownOperation := TBleOperation.Create(nil);
  FOperations.Add(FShutdownOperation);
  if FManager.State = lbcsShutdown then
    TBleOperationAccess(FShutdownOperation).Finish(lbopSucceeded)
  else if FManager.BeginShutdown = InvalidBleOperationId then
    TBleOperationAccess(FShutdownOperation).Finish(lbopFailed, 0,
      'Could not start BLE shutdown');
  Result := FShutdownOperation;
end;

end.
