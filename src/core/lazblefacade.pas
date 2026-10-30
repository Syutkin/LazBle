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
  LazBleClient,
  LazBleReconnect;

type
  ELazBleDuplicateClient = class(Exception);

  { Main-thread, FPC-only facade. The default constructor selects SimpleBLE;
    passing ILazBleBackend lets applications use another implementation.
    Creation and diagnostic reads do not start native BLE work. }
  TLazBle = class
  private
    FBackend: ILazBleBackend;
    FSessions: TList;
    FScanId, FAvailabilityId: TBleOperationId;
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
    procedure ScanFinished(Sender: TObject);
    procedure AvailabilityFinished(Sender: TObject);
    procedure CancelPendingOperations;
    function GetOrCreateSession(const ADeviceId: string): TBleGattSession;
    function SubmitCommand(const ACommand: TLazBleBackendCommand;
      const ACompletion: ILazBleRequestCompletion = nil;
      const AValues: ILazBleValueSink = nil; const AScan: ILazBleScanSink = nil;
      const ALink: ILazBleLinkObserver = nil): TBleOperationId;
    procedure CancelOperation(const AOperationId: TBleOperationId);
    procedure FinishSessions;
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
    procedure PrepareShutdownInternal;
    constructor CreateInternal(const ASession: TBleGattSession;
      const AReconnectTimer: ILazBleReconnectTimer);
  end;

  TBleGattSessionAccess = class(TBleGattSession)
  public
    constructor CreateInternal(const ADeviceId: string;
      const ASubmit: TLazBleSubmitCommand; const ACancel: TLazBleCancelOperation);
    procedure PrepareShutdownInternal;
    procedure FinishShutdownInternal;
  end;

  TShutdownOperation = class(TBleOperation)
  private
    FOwner: TLazBle;
  protected
    procedure CompleteRequest(const AResult: TLazBleRequestResult); override;
  public
    constructor Create(AOwner: TLazBle);
    procedure DetachOwner;
    procedure Finish(const AState: TLazBleOperationState;
      const AErrorCode: Integer = 0; const AErrorMessage: string = '');
  end;

  TBleScanOperationAccess = class(TBleScanOperation)
  public
    procedure CloseResultsInternal;
    constructor CreateInternal(
      const AOnCancel: TLazBleOperationCancelEvent);
    procedure Finish(const AState: TLazBleOperationState;
      const AErrorCode: Integer = 0; const AErrorMessage: string = '');
    procedure SetFinishing(const AHandler: TLazBleOperationCompletedEvent);
  end;

  TBleAvailabilityOperationAccess = class(TBleAvailabilityOperation)
  public
    constructor CreateInternal(
      const AOnCancel: TLazBleOperationCancelEvent);
    procedure Finish(const AState: TLazBleOperationState;
      const AErrorCode: Integer = 0; const AErrorMessage: string = '');
    procedure SetFinishing(const AHandler: TLazBleOperationCompletedEvent);
  end;

constructor TBleClientAccess.CreateInternal(const ASession: TBleGattSession;
  const AReconnectTimer: ILazBleReconnectTimer);
begin
  inherited Create(ASession, AReconnectTimer);
end;

procedure TBleClientAccess.PrepareShutdownInternal;
begin PrepareShutdown; end;

constructor TBleGattSessionAccess.CreateInternal(const ADeviceId: string;
  const ASubmit: TLazBleSubmitCommand; const ACancel: TLazBleCancelOperation);
begin inherited Create(ADeviceId, ASubmit, ACancel); end;

procedure TBleGattSessionAccess.PrepareShutdownInternal;
begin PrepareShutdown; end;

procedure TBleGattSessionAccess.FinishShutdownInternal;
begin HandleBackendShutdown; end;

constructor TShutdownOperation.Create(AOwner: TLazBle);
begin inherited Create(nil); FOwner := AOwner; end;

procedure TShutdownOperation.DetachOwner;
begin FOwner := nil; end;

procedure TShutdownOperation.CompleteRequest(const AResult: TLazBleRequestResult);
var Owner: TLazBle; KeepAlive: IBleOperation;
begin
  LazBleRequireMainThread;
  KeepAlive := Self;
  if State <> lbopPending then Exit;
  Owner := FOwner;
  FOwner := nil;
  if Owner <> nil then Owner.FinishSessions;
  inherited CompleteRequest(AResult);
end;

procedure TShutdownOperation.Finish(const AState: TLazBleOperationState;
  const AErrorCode: Integer; const AErrorMessage: string);
begin Complete(AState, AErrorCode, AErrorMessage); end;

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

procedure TBleAvailabilityOperationAccess.SetFinishing(const AHandler: TLazBleOperationCompletedEvent);
begin OnFinishing := AHandler; end;

procedure TBleScanOperationAccess.SetFinishing(const AHandler: TLazBleOperationCompletedEvent);
begin OnFinishing := AHandler; end;

procedure TBleScanOperationAccess.CloseResultsInternal;
begin CloseResults; end;

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
  FBackend := ABackend;
  FSessions := TList.Create;
end;

destructor TLazBle.Destroy;
var
  Index: Integer;
begin
  if FShutdownOperation = nil then
  begin
    FShutdownOperationObject := TShutdownOperation.Create(Self);
    FShutdownOperation := FShutdownOperationObject;
  end;
  TShutdownOperation(FShutdownOperationObject).DetachOwner;
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
    TShutdownOperation(FShutdownOperationObject).Finish(lbopCancelled);
  end;
  if FClients <> nil then
    for Index := FClients.Count - 1 downto 0 do TObject(FClients[Index]).Free;
  FClients.Free;
  if FBackend <> nil then FBackend.BeginShutdown;
  if FSessions <> nil then
    for Index := FSessions.Count - 1 downto 0 do TObject(FSessions[Index]).Free;
  FSessions.Free;
  FBackend := nil;
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
  if Sender = FActiveScanObject then CancelOperation(FScanId)
  else if Sender = FActiveAvailabilityObject then CancelOperation(FAvailabilityId);
end;

procedure TLazBle.ScanFinished(Sender: TObject);
begin
  if Sender <> FActiveScanObject then Exit;
  FActiveScan := nil;
  FActiveScanObject := nil;
  FScanId := InvalidBleOperationId;
end;

procedure TLazBle.AvailabilityFinished(Sender: TObject);
var Operation: TBleAvailabilityOperationAccess; R: TLazBleRequestResult;
begin
  if Sender <> FActiveAvailabilityObject then Exit;
  Operation := TBleAvailabilityOperationAccess(Sender);
  R := Operation.BackendResult;
  FActiveAvailability := nil;
  FActiveAvailabilityObject := nil;
  FAvailabilityId := InvalidBleOperationId;
  FDiagnosticInfo.BackendName := FBackendName;
  if R.BackendName <> '' then FDiagnosticInfo.BackendName := R.BackendName;
  FDiagnosticInfo.NativeVersion := R.BackendVersion;
  FDiagnosticInfo.AdapterId := R.AdapterId;
  FDiagnosticInfo.AvailabilityErrorMessage := '';
  case Operation.State of
    lbopSucceeded: FDiagnosticInfo.Availability := Operation.Availability;
    lbopCancelled: FDiagnosticInfo.Availability := lbaUnknown;
    lbopFailed:
      begin
        FDiagnosticInfo.Availability := lbaUnavailable;
        FDiagnosticInfo.AvailabilityErrorMessage := Operation.ErrorMessage;
      end;
  end;
  if FShutdownOperation <> nil then FDiagnosticInfo.Availability := lbaUnavailable;
end;

procedure TLazBle.CancelPendingOperations;
var Index: Integer;
begin
  LazBleRequireMainThread;
  for Index := 0 to FClients.Count - 1 do
    TBleClientAccess(FClients[Index]).PrepareShutdownInternal;
  if Assigned(FActiveScan) and (FActiveScan.State = lbopPending) then
  begin
    TBleScanOperationAccess(FActiveScanObject).CloseResultsInternal;
    FActiveScan.Cancel;
  end;
  if Assigned(FActiveAvailability) and (FActiveAvailability.State = lbopPending) then
    FActiveAvailability.Cancel;
  for Index := 0 to FClients.Count - 1 do
    TBleClientAccess(FClients[Index]).CancelForShutdown;
end;

function TLazBle.CheckAvailabilityAsync(const AAdapterId: string):
  IBleAvailabilityOperation;
var
  Operation: TBleAvailabilityOperationAccess;
  Command: TLazBleBackendCommand;
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
  Operation.SetFinishing(@AvailabilityFinished);
  FAvailabilityId := InvalidBleOperationId;
  if (FActiveScan = nil) or (FActiveScan.State <> lbopPending) then
  begin
    Command := Default(TLazBleBackendCommand);
    Command.Kind := lbckCheckAvailability; Command.AdapterId := AAdapterId;
    FAvailabilityId := SubmitCommand(Command, Operation);
  end;
  if FAvailabilityId = InvalidBleOperationId then
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
  Command: TLazBleBackendCommand;
begin
  LazBleRequireMainThread;
  if Assigned(FActiveScan) and (FActiveScan.State = lbopPending) then
    Exit(FActiveScan);
  Operation := TBleScanOperationAccess.CreateInternal(@OperationCancelled);
  Result := Operation;
  FActiveScan := Result;
  FActiveScanObject := Operation;
  Operation.SetFinishing(@ScanFinished);
  FScanId := InvalidBleOperationId;
  if (FShutdownOperation = nil) and
    ((FActiveAvailability = nil) or (FActiveAvailability.State <> lbopPending)) then
  begin
    Command := Default(TLazBleBackendCommand);
    Command.Kind := lbckStartScan; Command.AdapterId := AAdapterId; Command.TimeoutMs := ATimeoutMs;
    FScanId := SubmitCommand(Command, Operation, nil, Operation);
  end;
  if FScanId = InvalidBleOperationId then
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
  Session := GetOrCreateSession(ADeviceId);
  if not Assigned(Session) then
    raise EInvalidOperation.Create(
      'Cannot create a BLE client after shutdown has started');
  Result := TBleClientAccess.CreateInternal(Session, FReconnectTimerFactory.CreateTimer);
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

function TLazBle.GetOrCreateSession(const ADeviceId: string): TBleGattSession;
var I: Integer;
begin
  if FShutdownOperation <> nil then Exit(nil);
  for I := 0 to FSessions.Count - 1 do
    if TBleGattSession(FSessions[I]).DeviceId = ADeviceId then
      Exit(TBleGattSession(FSessions[I]));
  Result := TBleGattSessionAccess.CreateInternal(ADeviceId, @SubmitCommand, @CancelOperation);
  FSessions.Add(Result);
end;

function TLazBle.SubmitCommand(const ACommand: TLazBleBackendCommand;
  const ACompletion: ILazBleRequestCompletion; const AValues: ILazBleValueSink;
  const AScan: ILazBleScanSink; const ALink: ILazBleLinkObserver): TBleOperationId;
begin
  LazBleRequireMainThread;
  { Profile detachment can submit irreversible cleanup before BeginShutdown.
    New application work is already closed; the backend owns physical cleanup. }
  if (FBackend = nil) or ((FShutdownOperation <> nil) and
    (ACommand.Kind <> lbckUnsubscribe)) then Exit(InvalidBleOperationId);
  Result := FBackend.Submit(ACommand, ACompletion, AValues, AScan, ALink);
end;

procedure TLazBle.CancelOperation(const AOperationId: TBleOperationId);
begin
  LazBleRequireMainThread;
  if FBackend <> nil then FBackend.Cancel(AOperationId);
end;

procedure TLazBle.FinishSessions;
var I: Integer;
begin
  for I := 0 to FSessions.Count - 1 do
    try
      TBleGattSessionAccess(FSessions[I]).FinishShutdownInternal;
    except LazBleReportCallbackException; end;
end;

function TLazBle.ShutdownAsync: IBleOperation;
var Operation: TShutdownOperation; I: Integer;
begin
  LazBleRequireMainThread;
  if FShutdownOperation <> nil then Exit(FShutdownOperation);
  Operation := TShutdownOperation.Create(Self);
  FShutdownOperation := Operation;
  FShutdownOperationObject := Operation;
  Result := FShutdownOperation;
  FDiagnosticInfo.Availability := lbaUnavailable;
  for I := 0 to FSessions.Count - 1 do
    TBleGattSessionAccess(FSessions[I]).PrepareShutdownInternal;
  CancelPendingOperations;
  if FBackend.BeginShutdown(Operation) = InvalidBleOperationId then
  begin
    FinishSessions;
    Operation.DetachOwner;
    Operation.Finish(lbopFailed, 0, 'Could not start BLE shutdown');
  end;
end;

end.
