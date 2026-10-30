unit LazBleOperation;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  LazBleTypes, LazBleBackend;

type
  TLazBleOperationState = (
    lbopPending,
    lbopSucceeded,
    lbopFailed,
    lbopCancelled
  );

  TLazBleOperationCompletedEvent = procedure(Sender: TObject) of object;
  TLazBleOperationCancelEvent = procedure(Sender: TObject) of object;

  { Main-thread asynchronous request. Keep the interface while observing its
    result; OnCompleted also fires when assigned after completion. }
  IBleOperation = interface
    ['{5FCBB469-393D-4D89-AC6D-54E2B2F10292}']
    function GetState: TLazBleOperationState;
    function GetErrorCode: Integer;
    function GetErrorMessage: string;
    function GetCancelRequested: Boolean;
    function GetOnCompleted: TLazBleOperationCompletedEvent;
    procedure SetOnCompleted(const AHandler: TLazBleOperationCompletedEvent);
    { Best-effort request; only a backend outcome completes a submitted command.
      Started native calls and orderly shutdown may still succeed or fail. }
    procedure Cancel;
    property State: TLazBleOperationState read GetState;
    property ErrorCode: Integer read GetErrorCode;
    property ErrorMessage: string read GetErrorMessage;
    property CancelRequested: Boolean read GetCancelRequested;
    property OnCompleted: TLazBleOperationCompletedEvent
      read GetOnCompleted write SetOnCompleted;
  end;

  { Scan results accumulate in Results; OnResult reports discoveries. }
  IBleScanOperation = interface(IBleOperation)
    ['{F9EA6B8B-E7D5-42B5-9F9B-58076D923CFA}']
    function GetResults: TBleDeviceInfos;
    function GetOnResult: TLazBleScanResultEvent;
    procedure SetOnResult(const AHandler: TLazBleScanResultEvent);
    property Results: TBleDeviceInfos read GetResults;
    property OnResult: TLazBleScanResultEvent read GetOnResult
      write SetOnResult;
  end;

  { Availability contains the adapter status after successful completion. }
  IBleAvailabilityOperation = interface(IBleOperation)
    ['{5E357BDF-4930-4D8A-A112-EAF6FBD1975F}']
    function GetAvailability: TBleAvailability;
    property Availability: TBleAvailability read GetAvailability;
  end;

  TBleOperation = class(TInterfacedObject, IBleOperation, ILazBleRequestCompletion)
  private
    FState: TLazBleOperationState;
    FErrorCode: Integer;
    FErrorMessage: string;
    FCancelRequested: Boolean;
    FOnCancel: TLazBleOperationCancelEvent;
    FOnCompleted: TLazBleOperationCompletedEvent;
    FOnFinishing: TLazBleOperationCompletedEvent;
    FCompletionDelivered: Boolean;
    procedure NotifyCompleted;
  protected
    procedure CompleteRequest(const AResult: TLazBleRequestResult); virtual;
    function GetState: TLazBleOperationState;
    function GetErrorCode: Integer;
    function GetErrorMessage: string;
    function GetCancelRequested: Boolean;
    function GetOnCompleted: TLazBleOperationCompletedEvent;
    procedure SetOnCompleted(const AHandler: TLazBleOperationCompletedEvent);
    function Complete(const AState: TLazBleOperationState;
      const AErrorCode: Integer = 0;
      const AErrorMessage: string = ''): Boolean;
    procedure DetachCancelHandler;
    { Owner bookkeeping/continuation, independent of the public callback. }
    property OnFinishing: TLazBleOperationCompletedEvent read FOnFinishing write FOnFinishing;
  protected
    constructor Create(const AOnCancel: TLazBleOperationCancelEvent);
  public
    destructor Destroy; override;
    procedure Cancel;
    property State: TLazBleOperationState read GetState;
    property ErrorCode: Integer read GetErrorCode;
    property ErrorMessage: string read GetErrorMessage;
    property CancelRequested: Boolean read GetCancelRequested;
    property OnCompleted: TLazBleOperationCompletedEvent
      read GetOnCompleted write SetOnCompleted;
  end;

  TBleScanOperation = class(TBleOperation, IBleScanOperation, ILazBleScanSink)
  private
    FClosing: Boolean;
    FResults: TBleDeviceInfos;
    FOnResult: TLazBleScanResultEvent;
    function GetResults: TBleDeviceInfos;
    function GetOnResult: TLazBleScanResultEvent;
    procedure SetOnResult(const AHandler: TLazBleScanResultEvent);
  protected
    constructor Create(const AOnCancel: TLazBleOperationCancelEvent);
    procedure AddOrUpdateResult(const ADeviceId, ADeviceName: string;
      const ARssi: SmallInt);
    procedure CompleteRequest(const AResult: TLazBleRequestResult); override;
    procedure ReceiveScanResult(const ADevice: TBleDeviceInfo);
    procedure CloseResults;
  public
    destructor Destroy; override;
    property Results: TBleDeviceInfos read GetResults;
    property OnResult: TLazBleScanResultEvent read GetOnResult
      write SetOnResult;
  end;

  TBleAvailabilityOperation = class(TBleOperation,
    IBleAvailabilityOperation)
  private
    FAvailability: TBleAvailability;
    FBackendResult: TLazBleRequestResult;
    function GetAvailability: TBleAvailability;
  protected
    constructor Create(const AOnCancel: TLazBleOperationCancelEvent);
    procedure SetAvailability(const AAvailability: TBleAvailability);
    procedure CompleteRequest(const AResult: TLazBleRequestResult); override;
    property BackendResult: TLazBleRequestResult read FBackendResult;
  public
    destructor Destroy; override;
    property Availability: TBleAvailability read GetAvailability;
  end;

implementation

procedure TBleOperation.CompleteRequest(const AResult: TLazBleRequestResult);
begin
  LazBleRequireMainThread;
  case AResult.Status of
    lbrsSucceeded: Complete(lbopSucceeded);
    lbrsFailed: Complete(lbopFailed, AResult.ErrorCode, AResult.ErrorMessage);
    lbrsCancelled: Complete(lbopCancelled, AResult.ErrorCode, AResult.ErrorMessage);
  end;
end;

procedure TBleScanOperation.ReceiveScanResult(const ADevice: TBleDeviceInfo);
begin
  LazBleRequireMainThread;
  if State = lbopPending then
    AddOrUpdateResult(ADevice.DeviceId, ADevice.DeviceName, ADevice.Rssi);
end;

procedure TBleScanOperation.CompleteRequest(const AResult: TLazBleRequestResult);
var Device: TBleDeviceInfo;
begin
  LazBleRequireMainThread;
  if State <> lbopPending then Exit;
  for Device in AResult.ScanResults do
    AddOrUpdateResult(Device.DeviceId, Device.DeviceName, Device.Rssi);
  inherited CompleteRequest(AResult);
end;

procedure TBleScanOperation.CloseResults;
begin
  LazBleRequireMainThread;
  FClosing := True;
end;

procedure TBleAvailabilityOperation.CompleteRequest(const AResult: TLazBleRequestResult);
begin
  LazBleRequireMainThread;
  if State <> lbopPending then Exit;
  FBackendResult := AResult;
  if AResult.Status = lbrsSucceeded then
  begin
    if not (AResult.Availability in [lbaAvailable, lbaUnavailable]) then
    begin
      Complete(lbopFailed, 0, 'BLE backend did not report availability');
      Exit;
    end;
    FAvailability := AResult.Availability;
  end;
  inherited CompleteRequest(AResult);
end;

function SameCompletedHandler(const AFirst,
  ASecond: TLazBleOperationCompletedEvent): Boolean;
begin
  Result := (TMethod(AFirst).Code = TMethod(ASecond).Code) and
    (TMethod(AFirst).Data = TMethod(ASecond).Data);
end;

constructor TBleAvailabilityOperation.Create(
  const AOnCancel: TLazBleOperationCancelEvent);
begin
  inherited Create(AOnCancel);
  FAvailability := lbaUnknown;
end;

destructor TBleAvailabilityOperation.Destroy;
begin
  inherited Destroy;
end;

function TBleAvailabilityOperation.GetAvailability: TBleAvailability;
begin
  LazBleRequireMainThread;
  Result := FAvailability;
end;

procedure TBleAvailabilityOperation.SetAvailability(
  const AAvailability: TBleAvailability);
begin
  LazBleRequireMainThread;
  if AAvailability in [lbaUnknown, lbaChecking] then
    raise EArgumentException.Create(
      'A terminal BLE availability result is required');
  FAvailability := AAvailability;
end;

constructor TBleOperation.Create(
  const AOnCancel: TLazBleOperationCancelEvent);
begin
  inherited Create;
  FState := lbopPending;
  FOnCancel := AOnCancel;
end;

destructor TBleOperation.Destroy;
begin
  FOnCompleted := nil;
  FOnCancel := nil;
  FOnFinishing := nil;
  inherited Destroy;
end;

function TBleOperation.GetState: TLazBleOperationState;
begin
  LazBleRequireMainThread;
  Result := FState;
end;

function TBleOperation.GetErrorCode: Integer;
begin
  LazBleRequireMainThread;
  Result := FErrorCode;
end;

function TBleOperation.GetErrorMessage: string;
begin
  LazBleRequireMainThread;
  Result := FErrorMessage;
end;

function TBleOperation.GetCancelRequested: Boolean;
begin
  LazBleRequireMainThread;
  Result := FCancelRequested;
end;

function TBleOperation.GetOnCompleted: TLazBleOperationCompletedEvent;
begin
  LazBleRequireMainThread;
  Result := FOnCompleted;
end;

procedure TBleOperation.SetOnCompleted(
  const AHandler: TLazBleOperationCompletedEvent);
var
  NotifyNow: Boolean;
  KeepAlive: IBleOperation;
begin
  LazBleRequireMainThread;
  KeepAlive := Self;
  if not SameCompletedHandler(FOnCompleted, AHandler) then
    FCompletionDelivered := False;
  FOnCompleted := AHandler;
  NotifyNow := Assigned(AHandler) and
    (FState <> lbopPending) and not FCompletionDelivered;
  if NotifyNow then
    FCompletionDelivered := True;
  if NotifyNow then
    AHandler(Self);
end;

procedure TBleOperation.NotifyCompleted;
var
  Handler: TLazBleOperationCompletedEvent;
begin
  LazBleRequireMainThread;
  Handler := nil;
  if Assigned(FOnCompleted) and not FCompletionDelivered then
  begin
    Handler := FOnCompleted;
    FCompletionDelivered := True;
  end;
  if Assigned(Handler) then
    Handler(Self);
end;

function TBleOperation.Complete(const AState: TLazBleOperationState;
  const AErrorCode: Integer; const AErrorMessage: string): Boolean;
var
  KeepAlive: IBleOperation;
  Finishing: TLazBleOperationCompletedEvent;
begin
  LazBleRequireMainThread;
  KeepAlive := Self;
  if AState = lbopPending then
    raise EArgumentException.Create('A terminal operation state is required');
  Result := FState = lbopPending;
  if Result then
  begin
    FState := AState;
    FErrorCode := AErrorCode;
    FErrorMessage := AErrorMessage;
    FOnCancel := nil;
    Finishing := FOnFinishing;
    FOnFinishing := nil;
    if Assigned(Finishing) then Finishing(Self);
  end;
  if Result then
    NotifyCompleted;
end;

procedure TBleOperation.DetachCancelHandler;
begin
  LazBleRequireMainThread;
  FOnCancel := nil;
end;

procedure TBleOperation.Cancel;
var
  CancelHandler: TLazBleOperationCancelEvent;
begin
  LazBleRequireMainThread;
  if (FState <> lbopPending) or FCancelRequested then
    Exit;
  FCancelRequested := True;
  CancelHandler := FOnCancel;
  if Assigned(CancelHandler) then
    CancelHandler(Self);
end;

constructor TBleScanOperation.Create(
  const AOnCancel: TLazBleOperationCancelEvent);
begin
  inherited Create(AOnCancel);
end;

destructor TBleScanOperation.Destroy;
begin
  FOnResult := nil;
  FResults := nil;
  inherited Destroy;
end;

procedure TBleScanOperation.AddOrUpdateResult(const ADeviceId,
  ADeviceName: string; const ARssi: SmallInt);
var
  Found: Boolean;
  Handler: TLazBleScanResultEvent;
  Index: Integer;
  ResultInfo: TBleDeviceInfo;
begin
  LazBleRequireMainThread;
  Found := False;
  for Index := 0 to High(FResults) do
    if SameText(FResults[Index].DeviceId, ADeviceId) then
    begin
      FResults[Index].DeviceName := ADeviceName;
      FResults[Index].Rssi := ARssi;
      ResultInfo := FResults[Index];
      Found := True;
      Break;
    end;
  if not Found then
  begin
    Index := Length(FResults);
    SetLength(FResults, Index + 1);
    FResults[Index].DeviceId := ADeviceId;
    FResults[Index].DeviceName := ADeviceName;
    FResults[Index].Rssi := ARssi;
    ResultInfo := FResults[Index];
  end;
  Handler := GetOnResult;
  if not FClosing and Assigned(Handler) then
    try
      Handler(Self, ResultInfo.DeviceId, ResultInfo.DeviceName, ResultInfo.Rssi);
    except LazBleReportCallbackException; end;
end;

function TBleScanOperation.GetResults: TBleDeviceInfos;
begin
  LazBleRequireMainThread;
  Result := Copy(FResults);
end;

function TBleScanOperation.GetOnResult: TLazBleScanResultEvent;
begin
  LazBleRequireMainThread;
  Result := FOnResult;
end;

procedure TBleScanOperation.SetOnResult(
  const AHandler: TLazBleScanResultEvent);
begin
  LazBleRequireMainThread;
  FOnResult := AHandler;
end;

end.
