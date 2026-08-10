unit LazBleOperation;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  LazBleTypes;

type
  TLazBleOperationState = (
    lbopPending,
    lbopSucceeded,
    lbopFailed,
    lbopCancelled,
    lbopTimedOut
  );

  TLazBleOperationCompletedEvent = procedure(Sender: TObject) of object;
  TLazBleOperationCancelEvent = procedure(Sender: TObject) of object;

  IBleOperation = interface
    ['{5FCBB469-393D-4D89-AC6D-54E2B2F10292}']
    function GetState: TLazBleOperationState;
    function GetErrorCode: Integer;
    function GetErrorMessage: string;
    function GetCancelRequested: Boolean;
    function GetOnCompleted: TLazBleOperationCompletedEvent;
    procedure SetOnCompleted(const AHandler: TLazBleOperationCompletedEvent);
    procedure Cancel;
    procedure Timeout;
    property State: TLazBleOperationState read GetState;
    property ErrorCode: Integer read GetErrorCode;
    property ErrorMessage: string read GetErrorMessage;
    property CancelRequested: Boolean read GetCancelRequested;
    property OnCompleted: TLazBleOperationCompletedEvent
      read GetOnCompleted write SetOnCompleted;
  end;

  IBleScanOperation = interface(IBleOperation)
    ['{3D8E2E8C-A911-49F6-BA6D-C766FF684B91}']
    function GetResults: TBleDeviceInfos;
    property Results: TBleDeviceInfos read GetResults;
  end;

  TBleOperation = class(TInterfacedObject, IBleOperation)
  private
    FLock: TRTLCriticalSection;
    FCallbackLock: TRTLCriticalSection;
    FState: TLazBleOperationState;
    FErrorCode: Integer;
    FErrorMessage: string;
    FCancelRequested: Boolean;
    FOnCancel: TLazBleOperationCancelEvent;
    FOnCompleted: TLazBleOperationCompletedEvent;
    FCompletionDelivered: Boolean;
    procedure NotifyCompleted;
  protected
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
  protected
    constructor Create(const AOnCancel: TLazBleOperationCancelEvent);
  public
    destructor Destroy; override;
    procedure Cancel;
    procedure Timeout;
    property State: TLazBleOperationState read GetState;
    property ErrorCode: Integer read GetErrorCode;
    property ErrorMessage: string read GetErrorMessage;
    property CancelRequested: Boolean read GetCancelRequested;
    property OnCompleted: TLazBleOperationCompletedEvent
      read GetOnCompleted write SetOnCompleted;
  end;

  TBleScanOperation = class(TBleOperation, IBleScanOperation)
  private
    FResultsLock: TRTLCriticalSection;
    FResults: TBleDeviceInfos;
    function GetResults: TBleDeviceInfos;
  protected
    constructor Create(const AOnCancel: TLazBleOperationCancelEvent);
    procedure AddOrUpdateResult(const ADeviceId, ADeviceName: string;
      const ARssi: SmallInt);
  public
    destructor Destroy; override;
    property Results: TBleDeviceInfos read GetResults;
  end;

implementation

function SameCompletedHandler(const AFirst,
  ASecond: TLazBleOperationCompletedEvent): Boolean;
begin
  Result := (TMethod(AFirst).Code = TMethod(ASecond).Code) and
    (TMethod(AFirst).Data = TMethod(ASecond).Data);
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
  EnterCriticalSection(FCallbackLock);
  try
    FOnCompleted := nil;
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
  EnterCriticalSection(FLock);
  try
    FOnCancel := nil;
  finally
    LeaveCriticalSection(FLock);
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

function TBleOperation.GetOnCompleted: TLazBleOperationCompletedEvent;
begin
  EnterCriticalSection(FCallbackLock);
  try
    Result := FOnCompleted;
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
end;

procedure TBleOperation.SetOnCompleted(
  const AHandler: TLazBleOperationCompletedEvent);
var
  NotifyNow: Boolean;
begin
  EnterCriticalSection(FCallbackLock);
  try
    if not SameCompletedHandler(FOnCompleted, AHandler) then
      FCompletionDelivered := False;
    FOnCompleted := AHandler;
    EnterCriticalSection(FLock);
    try
      NotifyNow := Assigned(AHandler) and
        (FState <> lbopPending) and not FCompletionDelivered;
      if NotifyNow then
        FCompletionDelivered := True;
    finally
      LeaveCriticalSection(FLock);
    end;
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
  if NotifyNow then
    AHandler(Self);
end;

procedure TBleOperation.NotifyCompleted;
var
  Handler: TLazBleOperationCompletedEvent;
begin
  Handler := nil;
  EnterCriticalSection(FCallbackLock);
  try
    if Assigned(FOnCompleted) and not FCompletionDelivered then
    begin
      Handler := FOnCompleted;
      FCompletionDelivered := True;
    end;
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
  if Assigned(Handler) then
    Handler(Self);
end;

function TBleOperation.Complete(const AState: TLazBleOperationState;
  const AErrorCode: Integer; const AErrorMessage: string): Boolean;
begin
  if AState = lbopPending then
    raise EArgumentException.Create('A terminal operation state is required');
  EnterCriticalSection(FLock);
  try
    Result := FState = lbopPending;
    if Result then
    begin
      FState := AState;
      FErrorCode := AErrorCode;
      FErrorMessage := AErrorMessage;
      FOnCancel := nil;
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
  if Result then
    NotifyCompleted;
end;

procedure TBleOperation.DetachCancelHandler;
begin
  EnterCriticalSection(FLock);
  try
    FOnCancel := nil;
  finally
    LeaveCriticalSection(FLock);
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
  TimedOut: Boolean;
begin
  EnterCriticalSection(FLock);
  try
    TimedOut := FState = lbopPending;
    if TimedOut then
    begin
      FCancelRequested := True;
      FState := lbopTimedOut;
      FErrorCode := 0;
      FErrorMessage := 'BLE operation timed out';
      CancelHandler := FOnCancel;
      FOnCancel := nil;
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
  if not TimedOut then
    Exit;
  if Assigned(CancelHandler) then
    CancelHandler(Self);
  NotifyCompleted;
end;

constructor TBleScanOperation.Create(
  const AOnCancel: TLazBleOperationCancelEvent);
begin
  inherited Create(AOnCancel);
  InitCriticalSection(FResultsLock);
end;

destructor TBleScanOperation.Destroy;
begin
  EnterCriticalSection(FResultsLock);
  try
    FResults := nil;
  finally
    LeaveCriticalSection(FResultsLock);
  end;
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

end.
