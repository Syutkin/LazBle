unit LazBleClientSync;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  LazBleTypes,
  LazBleBackend,
  LazBleGattSession,
  LazBleClient;

type
  TBleClientSync = class
  private
    FClient: TBleClient;
    function WaitForOperation(const AOperation: TBleClientOperation;
      const ATimeoutMs: Cardinal): Boolean;
  public
    constructor Create; overload;
    constructor Create(const ABackend: ILazBleBackend); overload;
    destructor Destroy; override;
    function Scan(const AAdapterId: string; const ATimeoutMs: Cardinal;
      out ADevices: TBleDeviceInfos; out AErrorMessage: string): Boolean;
    function Connect(const ADeviceId: string; const ATimeoutMs: Cardinal;
      out ASession: TBleGattSession; out AErrorMessage: string): Boolean;
    function Disconnect(const ASession: TBleGattSession;
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

constructor TBleClientSync.Create;
begin
  inherited Create;
  FClient := TBleClient.Create;
end;

constructor TBleClientSync.Create(const ABackend: ILazBleBackend);
begin
  inherited Create;
  FClient := TBleClient.Create(ABackend);
end;

destructor TBleClientSync.Destroy;
begin
  FClient.Free;
  inherited Destroy;
end;

function TBleClientSync.WaitForOperation(
  const AOperation: TBleClientOperation; const ATimeoutMs: Cardinal): Boolean;
var
  Waiter: TOperationWaiter;
begin
  if not Assigned(AOperation) then
    Exit(False);
  Waiter := TOperationWaiter.Create;
  try
    AOperation.OnCompleted := @Waiter.Completed;
    if (AOperation.State = lbcopsPending) and not Waiter.Wait(ATimeoutMs) then
      AOperation.Timeout;
    AOperation.OnCompleted := nil;
    Result := AOperation.State = lbcopsSucceeded;
  finally
    Waiter.Free;
  end;
end;

function TBleClientSync.Scan(const AAdapterId: string;
  const ATimeoutMs: Cardinal; out ADevices: TBleDeviceInfos;
  out AErrorMessage: string): Boolean;
var
  Operation: TBleScanOperation;
  WaitTimeoutMs: Cardinal;
begin
  Operation := FClient.ScanAsync(AAdapterId, ATimeoutMs);
  if ATimeoutMs > High(Cardinal) - 1000 then
    WaitTimeoutMs := High(Cardinal)
  else
    WaitTimeoutMs := ATimeoutMs + 1000;
  Result := WaitForOperation(Operation, WaitTimeoutMs);
  ADevices := Operation.Results;
  AErrorMessage := Operation.ErrorMessage;
end;

function TBleClientSync.Connect(const ADeviceId: string;
  const ATimeoutMs: Cardinal; out ASession: TBleGattSession;
  out AErrorMessage: string): Boolean;
var
  Operation: TBleConnectionOperation;
begin
  Operation := FClient.ConnectAsync(ADeviceId);
  Result := WaitForOperation(Operation, ATimeoutMs);
  ASession := Operation.Session;
  AErrorMessage := Operation.ErrorMessage;
end;

function TBleClientSync.Disconnect(const ASession: TBleGattSession;
  const ATimeoutMs: Cardinal; out AErrorMessage: string): Boolean;
var
  Operation: TBleConnectionOperation;
begin
  Operation := FClient.DisconnectAsync(ASession);
  Result := WaitForOperation(Operation, ATimeoutMs);
  AErrorMessage := Operation.ErrorMessage;
end;

function TBleClientSync.Shutdown(const ATimeoutMs: Cardinal;
  out AErrorMessage: string): Boolean;
var
  Operation: TBleClientOperation;
begin
  Operation := FClient.ShutdownAsync;
  Result := WaitForOperation(Operation, ATimeoutMs);
  AErrorMessage := Operation.ErrorMessage;
end;

end.
