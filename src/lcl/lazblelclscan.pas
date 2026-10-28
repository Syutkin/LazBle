unit LazBleLclScan;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  LazBleTypes,
  LazBleOperation,
  LazBleFacade;

type
  ELazBleLclScanActive = class(Exception);

  TLazBleLclScanState = (
    lblssIdle,
    lblssScanning,
    lblssSucceeded,
    lblssCancelled,
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
    FGeneration: QWord;
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

constructor TLazBleLclScan.Create(const ABle: TLazBle);
begin
  inherited Create;
  if not Assigned(ABle) then
    raise EArgumentNilException.Create('ABle');
  FBle := ABle;
  FState := lblssIdle;
end;

destructor TLazBleLclScan.Destroy;
begin
  Shutdown;
  FBle := nil;
  inherited Destroy;
end;

procedure TLazBleLclScan.Start(const AAdapterId: string;
  const ATimeoutMs: Cardinal);
var
  Generation: QWord;
begin
  LazBleRequireMainThread;
  if FShutdown then
    raise EInvalidOperation.Create('BLE scan controller is shut down');
  if State = lblssScanning then
    raise ELazBleLclScanActive.Create('BLE scan is already active');
  Inc(FGeneration);
  ClearResults;
  FErrorCode := 0;
  FErrorMessage := '';
  FState := lblssScanning;
  FOperation := FBle.ScanAsync(AAdapterId, ATimeoutMs);
  FOperation.OnResult := @OperationResult;
  Generation := FGeneration;
  NotifyStateChanged(lblssScanning);
  if FShutdown or (Generation <> FGeneration) then Exit;
  FOperation.OnCompleted := @OperationCompleted;
end;

procedure TLazBleLclScan.Cancel;
begin
  LazBleRequireMainThread;
  if Assigned(FOperation) and (FOperation.State = lbopPending) then
    FOperation.Cancel;
end;

procedure TLazBleLclScan.ClearResults;
begin
  LazBleRequireMainThread;
  SetLength(FResults, 0);
end;

procedure TLazBleLclScan.Shutdown;
var
  Operation: IBleScanOperation;
begin
  LazBleRequireMainThread;
  if FShutdown then
    Exit;
  FShutdown := True;
  Inc(FGeneration);
  Operation := FOperation;
  FOperation := nil;
  if Assigned(Operation) then
  begin
    Operation.OnResult := nil;
    Operation.OnCompleted := nil;
    if Operation.State = lbopPending then
      Operation.Cancel;
  end;
  if FState = lblssScanning then
    FState := lblssCancelled;
end;

function TLazBleLclScan.GetState: TLazBleLclScanState;
begin
  LazBleRequireMainThread;
  Result := FState;
end;

function TLazBleLclScan.GetResults: TBleDeviceInfos;
begin
  LazBleRequireMainThread;
  Result := FResults;
end;

function TLazBleLclScan.GetErrorCode: Integer;
begin
  LazBleRequireMainThread;
  Result := FErrorCode;
end;

function TLazBleLclScan.GetErrorMessage: string;
begin
  LazBleRequireMainThread;
  Result := FErrorMessage;
end;

procedure TLazBleLclScan.OperationResult(Sender: TObject;
  const ADeviceId, ADeviceName: string; const ARssi: SmallInt);
var
  DeviceInfo: TBleDeviceInfo;
begin
  LazBleRequireMainThread;
  if FShutdown or not Assigned(FOperation) or
    (FOperation <> (Sender as IBleScanOperation)) then Exit;
  DeviceInfo := Default(TBleDeviceInfo);
  DeviceInfo.DeviceId := ADeviceId;
  DeviceInfo.DeviceName := ADeviceName;
  DeviceInfo.Rssi := ARssi;
  DeliverResult(DeviceInfo);
end;

procedure TLazBleLclScan.OperationCompleted(Sender: TObject);
var
  Operation: IBleScanOperation;
begin
  LazBleRequireMainThread;
  if FShutdown or not Assigned(FOperation) or
    (FOperation <> (Sender as IBleScanOperation)) then Exit;
  Operation := FOperation;
  DeliverCompletion(Operation.State, Operation.ErrorCode, Operation.ErrorMessage);
end;

procedure TLazBleLclScan.DeliverResult(const ADeviceInfo: TBleDeviceInfo);
var
  Handler: TLazBleScanResultEvent;
  Index: Integer;
  ResultIndex: Integer;
begin
  ResultIndex := -1;
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
  FResults := Copy(FResults); { published snapshots remain unchanged }
  FResults[ResultIndex] := ADeviceInfo;

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
  Generation: QWord;
begin
  if State <> lblssScanning then
    Exit;

  case AOperationState of
    lbopSucceeded:
      NewState := lblssSucceeded;
    lbopCancelled:
      NewState := lblssCancelled;
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

  FState := NewState;
  FErrorCode := AErrorCode;
  FErrorMessage := AErrorMessage;
  Generation := FGeneration;
  NotifyStateChanged(NewState);
  if FShutdown or (Generation <> FGeneration) then Exit;

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
