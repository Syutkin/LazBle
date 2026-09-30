unit LazBleLclScan;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  LazBleTypes,
  LazBleOperation,
  LazBleFacade,
  LazBleLclDispatch;

type
  ELazBleLclScanActive = class(Exception);

  TLazBleLclScanState = (
    lblssIdle,
    lblssScanning,
    lblssSucceeded,
    lblssCancelled,
    lblssTimedOut,
    lblssFailed
  );

  TLazBleLclScanStateChangedEvent = procedure(Sender: TObject;
    const AState: TLazBleLclScanState) of object;
  TLazBleLclScanCompletedEvent = procedure(Sender: TObject;
    const AState: TLazBleLclScanState) of object;

  { LCL scan controller. Results and completion events are delivered on the
    main thread; keep ABle alive until this controller is destroyed. }
  TLazBleLclScan = class
  private
    FBle: TLazBle;
    FOperation: IBleScanOperation;
    FDispatch: TLazBleLclDispatch;
    FLock: TRTLCriticalSection;
    FState: TLazBleLclScanState;
    FResults: TBleDeviceInfos;
    FErrorCode: Integer;
    FErrorMessage: string;
    FShutdown: Boolean;
    FOnResult: TLazBleScanResultEvent;
    FOnStateChanged: TLazBleLclScanStateChangedEvent;
    FOnCompleted: TLazBleLclScanCompletedEvent;
    function GetState: TLazBleLclScanState;
    function GetResults: TBleDeviceInfos;
    function GetErrorCode: Integer;
    function GetErrorMessage: string;
    procedure OperationResult(Sender: TObject; const ADeviceId,
      ADeviceName: string; const ARssi: SmallInt);
    procedure OperationCompleted(Sender: TObject);
    procedure DispatchMessage(Sender: TObject;
      const AMessage: TLazBleLclDispatchMessage);
    procedure DeliverResult(const ADeviceInfo: TBleDeviceInfo);
    procedure DeliverCompletion(const AOperationState: TLazBleOperationState;
      const AErrorCode: Integer; const AErrorMessage: string);
    procedure NotifyStateChanged(const AState: TLazBleLclScanState);
  public
    constructor Create(const ABle: TLazBle);
    destructor Destroy; override;
    { Start one scan; raises ELazBleLclScanActive if already scanning. An empty
      adapter ID lets the backend select its default adapter. }
    procedure Start(const AAdapterId: string; const ATimeoutMs: Cardinal);
    { Request cancellation of the current scan. }
    procedure Cancel;
    { Clear saved results without starting a new scan. }
    procedure ClearResults;
    { Cancel activity and stop dispatching callbacks before destruction. }
    procedure Shutdown;
    property State: TLazBleLclScanState read GetState;
    property Results: TBleDeviceInfos read GetResults;
    property ErrorCode: Integer read GetErrorCode;
    property ErrorMessage: string read GetErrorMessage;
    property OnResult: TLazBleScanResultEvent read FOnResult write FOnResult;
    property OnStateChanged: TLazBleLclScanStateChangedEvent
      read FOnStateChanged write FOnStateChanged;
    property OnCompleted: TLazBleLclScanCompletedEvent
      read FOnCompleted write FOnCompleted;
  end;

implementation

type
  TLazBleLclScanResultMessage = class(TLazBleLclDispatchMessage)
  private
    FDeviceInfo: TBleDeviceInfo;
  public
    constructor Create(const ADeviceInfo: TBleDeviceInfo);
    function Clone: TLazBleLclDispatchMessage; override;
    property DeviceInfo: TBleDeviceInfo read FDeviceInfo;
  end;

  TLazBleLclScanCompletedMessage = class(TLazBleLclDispatchMessage)
  private
    FOperationState: TLazBleOperationState;
    FErrorCode: Integer;
    FErrorMessage: string;
  public
    constructor Create(const AOperationState: TLazBleOperationState;
      const AErrorCode: Integer; const AErrorMessage: string);
    function Clone: TLazBleLclDispatchMessage; override;
    property OperationState: TLazBleOperationState read FOperationState;
    property ErrorCode: Integer read FErrorCode;
    property ErrorMessage: string read FErrorMessage;
  end;

constructor TLazBleLclScanResultMessage.Create(
  const ADeviceInfo: TBleDeviceInfo);
begin
  inherited Create;
  FDeviceInfo := ADeviceInfo;
end;

function TLazBleLclScanResultMessage.Clone: TLazBleLclDispatchMessage;
begin
  Result := TLazBleLclScanResultMessage.Create(FDeviceInfo);
end;

constructor TLazBleLclScanCompletedMessage.Create(
  const AOperationState: TLazBleOperationState; const AErrorCode: Integer;
  const AErrorMessage: string);
begin
  inherited Create;
  FOperationState := AOperationState;
  FErrorCode := AErrorCode;
  FErrorMessage := AErrorMessage;
end;

function TLazBleLclScanCompletedMessage.Clone: TLazBleLclDispatchMessage;
begin
  Result := TLazBleLclScanCompletedMessage.Create(FOperationState,
    FErrorCode, FErrorMessage);
end;

constructor TLazBleLclScan.Create(const ABle: TLazBle);
begin
  inherited Create;
  if not Assigned(ABle) then
    raise EArgumentNilException.Create('ABle');
  InitCriticalSection(FLock);
  FBle := ABle;
  FState := lblssIdle;
  FDispatch := TLazBleLclDispatch.Create(@DispatchMessage);
end;

destructor TLazBleLclScan.Destroy;
begin
  Shutdown;
  FDispatch.Free;
  FDispatch := nil;
  FBle := nil;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TLazBleLclScan.Start(const AAdapterId: string;
  const ATimeoutMs: Cardinal);
begin
  if FShutdown then
    raise EInvalidOperation.Create('BLE scan controller is shut down');
  if State = lblssScanning then
    raise ELazBleLclScanActive.Create('BLE scan is already active');
  FDispatch.NextGeneration;
  ClearResults;
  EnterCriticalSection(FLock);
  try
    FErrorCode := 0;
    FErrorMessage := '';
    FState := lblssScanning;
  finally
    LeaveCriticalSection(FLock);
  end;
  FOperation := FBle.ScanAsync(AAdapterId, ATimeoutMs);
  FOperation.OnResult := @OperationResult;
  NotifyStateChanged(lblssScanning);
  FOperation.OnCompleted := @OperationCompleted;
end;

procedure TLazBleLclScan.Cancel;
begin
  if Assigned(FOperation) and (FOperation.State = lbopPending) then
    FOperation.Cancel;
end;

procedure TLazBleLclScan.ClearResults;
begin
  EnterCriticalSection(FLock);
  try
    SetLength(FResults, 0);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TLazBleLclScan.Shutdown;
var
  Operation: IBleScanOperation;
begin
  if FShutdown then
    Exit;
  FShutdown := True;
  FDispatch.Detach;
  Operation := FOperation;
  FOperation := nil;
  if Assigned(Operation) then
  begin
    Operation.OnResult := nil;
    Operation.OnCompleted := nil;
    if Operation.State = lbopPending then
      Operation.Cancel;
  end;
  EnterCriticalSection(FLock);
  try
    if FState = lblssScanning then
      FState := lblssCancelled;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TLazBleLclScan.GetState: TLazBleLclScanState;
begin
  EnterCriticalSection(FLock);
  try
    Result := FState;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TLazBleLclScan.GetResults: TBleDeviceInfos;
begin
  EnterCriticalSection(FLock);
  try
    Result := Copy(FResults);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TLazBleLclScan.GetErrorCode: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Result := FErrorCode;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TLazBleLclScan.GetErrorMessage: string;
begin
  EnterCriticalSection(FLock);
  try
    Result := FErrorMessage;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TLazBleLclScan.OperationResult(Sender: TObject;
  const ADeviceId, ADeviceName: string; const ARssi: SmallInt);
var
  DeviceInfo: TBleDeviceInfo;
  Message: TLazBleLclScanResultMessage;
begin
  DeviceInfo := Default(TBleDeviceInfo);
  DeviceInfo.DeviceId := ADeviceId;
  DeviceInfo.DeviceName := ADeviceName;
  DeviceInfo.Rssi := ARssi;
  Message := TLazBleLclScanResultMessage.Create(DeviceInfo);
  try
    FDispatch.Queue(Message);
  finally
    Message.Free;
  end;
end;

procedure TLazBleLclScan.OperationCompleted(Sender: TObject);
var
  Message: TLazBleLclScanCompletedMessage;
  Operation: TBleOperation;
begin
  if not (Sender is TBleOperation) then
    Exit;
  Operation := TBleOperation(Sender);
  Message := TLazBleLclScanCompletedMessage.Create(Operation.State,
    Operation.ErrorCode, Operation.ErrorMessage);
  try
    FDispatch.Queue(Message);
  finally
    Message.Free;
  end;
end;

procedure TLazBleLclScan.DispatchMessage(Sender: TObject;
  const AMessage: TLazBleLclDispatchMessage);
begin
  if AMessage is TLazBleLclScanResultMessage then
    DeliverResult(TLazBleLclScanResultMessage(AMessage).DeviceInfo)
  else if AMessage is TLazBleLclScanCompletedMessage then
    DeliverCompletion(
      TLazBleLclScanCompletedMessage(AMessage).OperationState,
      TLazBleLclScanCompletedMessage(AMessage).ErrorCode,
      TLazBleLclScanCompletedMessage(AMessage).ErrorMessage);
end;

procedure TLazBleLclScan.DeliverResult(const ADeviceInfo: TBleDeviceInfo);
var
  Handler: TLazBleScanResultEvent;
  Index: Integer;
  ResultIndex: Integer;
begin
  ResultIndex := -1;
  EnterCriticalSection(FLock);
  try
    if FState <> lblssScanning then
      Exit;
    for Index := 0 to High(FResults) do
      if FResults[Index].DeviceId = ADeviceInfo.DeviceId then
      begin
        ResultIndex := Index;
        Break;
      end;
    if ResultIndex < 0 then
    begin
      ResultIndex := Length(FResults);
      SetLength(FResults, ResultIndex + 1);
    end;
    FResults[ResultIndex] := ADeviceInfo;
  finally
    LeaveCriticalSection(FLock);
  end;

  Handler := FOnResult;
  if Assigned(Handler) then
    Handler(Self, ADeviceInfo.DeviceId, ADeviceInfo.DeviceName,
      ADeviceInfo.Rssi);
end;

procedure TLazBleLclScan.DeliverCompletion(
  const AOperationState: TLazBleOperationState; const AErrorCode: Integer;
  const AErrorMessage: string);
var
  CompletedHandler: TLazBleLclScanCompletedEvent;
  NewState: TLazBleLclScanState;
  Operation: IBleScanOperation;
begin
  if State <> lblssScanning then
    Exit;

  case AOperationState of
    lbopSucceeded:
      NewState := lblssSucceeded;
    lbopCancelled:
      NewState := lblssCancelled;
    lbopTimedOut:
      NewState := lblssTimedOut;
  else
    NewState := lblssFailed;
  end;

  Operation := FOperation;
  FOperation := nil;
  if Assigned(Operation) then
  begin
    Operation.OnResult := nil;
    Operation.OnCompleted := nil;
  end;

  EnterCriticalSection(FLock);
  try
    FState := NewState;
    FErrorCode := AErrorCode;
    FErrorMessage := AErrorMessage;
  finally
    LeaveCriticalSection(FLock);
  end;
  NotifyStateChanged(NewState);

  CompletedHandler := FOnCompleted;
  if Assigned(CompletedHandler) then
    CompletedHandler(Self, NewState);
end;

procedure TLazBleLclScan.NotifyStateChanged(
  const AState: TLazBleLclScanState);
var
  Handler: TLazBleLclScanStateChangedEvent;
begin
  Handler := FOnStateChanged;
  if Assigned(Handler) then
    Handler(Self, AState);
end;

end.
