unit LazBleSync;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  LazBleTypes,
  LazBleBackend,
  LazBleOperation,
  LazBleClient,
  LazBleFacade;

type
  TLazBleSync = class
  private
    FBle: TLazBle;
    function WaitForOperation(const AOperation: IBleOperation;
      const ATimeoutMs: Cardinal): Boolean;
  public
    constructor Create; overload;
    constructor Create(const ABackend: ILazBleBackend); overload;
    destructor Destroy; override;
    function Scan(const AAdapterId: string; const ATimeoutMs: Cardinal;
      out ADevices: TBleDeviceInfos; out AErrorMessage: string): Boolean;
    function CreateClient(const ADeviceId: string): TBleClient;
    function Connect(const AClient: TBleClient;
      const ATimeoutMs: Cardinal; out AErrorMessage: string): Boolean;
    function Disconnect(const AClient: TBleClient;
      const ATimeoutMs: Cardinal; out AErrorMessage: string): Boolean;
    function Shutdown(const ATimeoutMs: Cardinal;
      out AErrorMessage: string): Boolean;
  end;

implementation

uses
  SyncObjs;

type
  TOperationWaiter = class
  private
    FEvent: TEvent;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Completed(Sender: TObject);
    function Wait(const ATimeoutMs: Cardinal): Boolean;
  end;

constructor TOperationWaiter.Create;
begin
  inherited Create;
  FEvent := TEvent.Create(nil, True, False, '');
end;

destructor TOperationWaiter.Destroy;
begin
  FEvent.Free;
  inherited Destroy;
end;

procedure TOperationWaiter.Completed(Sender: TObject);
begin
  FEvent.SetEvent;
end;

function TOperationWaiter.Wait(const ATimeoutMs: Cardinal): Boolean;
begin
  Result := FEvent.WaitFor(ATimeoutMs) = wrSignaled;
end;

constructor TLazBleSync.Create;
begin
  inherited Create;
  FBle := TLazBle.Create;
end;

constructor TLazBleSync.Create(const ABackend: ILazBleBackend);
begin
  inherited Create;
  FBle := TLazBle.Create(ABackend);
end;

destructor TLazBleSync.Destroy;
begin
  FBle.Free;
  inherited Destroy;
end;

function TLazBleSync.WaitForOperation(const AOperation: IBleOperation;
  const ATimeoutMs: Cardinal): Boolean;
var
  Waiter: TOperationWaiter;
begin
  if not Assigned(AOperation) then
    Exit(False);
  Waiter := TOperationWaiter.Create;
  try
    AOperation.OnCompleted := @Waiter.Completed;
    if (AOperation.State = lbopPending) and not Waiter.Wait(ATimeoutMs) then
      AOperation.Timeout;
    AOperation.OnCompleted := nil;
    Result := AOperation.State = lbopSucceeded;
  finally
    Waiter.Free;
  end;
end;

function TLazBleSync.Scan(const AAdapterId: string;
  const ATimeoutMs: Cardinal; out ADevices: TBleDeviceInfos;
  out AErrorMessage: string): Boolean;
var
  Operation: IBleScanOperation;
  WaitTimeoutMs: Cardinal;
begin
  Operation := FBle.ScanAsync(AAdapterId, ATimeoutMs);
  if ATimeoutMs > High(Cardinal) - 1000 then
    WaitTimeoutMs := High(Cardinal)
  else
    WaitTimeoutMs := ATimeoutMs + 1000;
  Result := WaitForOperation(Operation, WaitTimeoutMs);
  ADevices := Operation.Results;
  AErrorMessage := Operation.ErrorMessage;
end;

function TLazBleSync.CreateClient(const ADeviceId: string): TBleClient;
begin
  Result := FBle.CreateClient(ADeviceId);
end;

function TLazBleSync.Connect(const AClient: TBleClient;
  const ATimeoutMs: Cardinal; out AErrorMessage: string): Boolean;
var
  Operation: IBleOperation;
begin
  if not Assigned(AClient) then
  begin
    AErrorMessage := 'BLE client is not assigned';
    Exit(False);
  end;
  Operation := AClient.ConnectAsync;
  Result := WaitForOperation(Operation, ATimeoutMs);
  AErrorMessage := Operation.ErrorMessage;
end;

function TLazBleSync.Disconnect(const AClient: TBleClient;
  const ATimeoutMs: Cardinal; out AErrorMessage: string): Boolean;
var
  Operation: IBleOperation;
begin
  if not Assigned(AClient) then
  begin
    AErrorMessage := 'BLE client is not assigned';
    Exit(False);
  end;
  Operation := AClient.DisconnectAsync;
  Result := WaitForOperation(Operation, ATimeoutMs);
  AErrorMessage := Operation.ErrorMessage;
end;

function TLazBleSync.Shutdown(const ATimeoutMs: Cardinal;
  out AErrorMessage: string): Boolean;
var
  Operation: IBleOperation;
begin
  Operation := FBle.ShutdownAsync;
  Result := WaitForOperation(Operation, ATimeoutMs);
  AErrorMessage := Operation.ErrorMessage;
end;

end.
