unit LazBleCentralManager;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  LazBleTypes,
  LazBleBackend,
  LazBleGattSession;

type
  TLazBleCentralState = (
    lbcsIdle,
    lbcsScanning,
    lbcsShuttingDown,
    lbcsShutdown
  );

  TLazBleScanResultEvent = procedure(Sender: TObject; const ADeviceId,
    ADeviceName: string; const ARssi: SmallInt) of object;
  TLazBleScanCompletedEvent = procedure(Sender: TObject;
    const ASucceeded: Boolean; const AErrorCode: Integer;
    const AErrorMessage: string) of object;

  TBleCentralManager = class;

  TLazBleManagerEventSink = class(TInterfacedObject,
    ILazBleBackendEventSink)
  private
    FManager: TBleCentralManager;
  public
    constructor Create(const AManager: TBleCentralManager);
    procedure Detach;
    procedure HandleBackendEvent(const AEvent: TLazBleBackendEvent);
  end;

  TBleCentralManager = class
  private
    FBackend: ILazBleBackend;
    FEventSink: ILazBleBackendEventSink;
    FEventSinkObject: TLazBleManagerEventSink;
    FSessions: TList;
    FState: TLazBleCentralState;
    FScanOperationId: TBleOperationId;
    FShutdownOperationId: TBleOperationId;
    FOnScanResult: TLazBleScanResultEvent;
    FOnScanCompleted: TLazBleScanCompletedEvent;
    function SubmitCommand(
      const ACommand: TLazBleBackendCommand): TBleOperationId;
    procedure CancelOperation(const AOperationId: TBleOperationId);
    procedure HandleBackendEvent(const AEvent: TLazBleBackendEvent);
  public
    constructor Create(const ABackend: ILazBleBackend);
    destructor Destroy; override;
    function StartScan(const AAdapterId: string;
      const ATimeoutMs: Cardinal): TBleOperationId;
    function CreateSession(const ADeviceId: string): TBleGattSession;
    function BeginShutdown: TBleOperationId;
    property State: TLazBleCentralState read FState;
    property OnScanResult: TLazBleScanResultEvent read FOnScanResult
      write FOnScanResult;
    property OnScanCompleted: TLazBleScanCompletedEvent read FOnScanCompleted
      write FOnScanCompleted;
  end;

implementation

constructor TLazBleManagerEventSink.Create(
  const AManager: TBleCentralManager);
begin
  inherited Create;
  FManager := AManager;
end;

procedure TBleCentralManager.CancelOperation(
  const AOperationId: TBleOperationId);
begin
  if Assigned(FBackend) and
    not (FState in [lbcsShuttingDown, lbcsShutdown]) then
    FBackend.Cancel(AOperationId);
end;

procedure TLazBleManagerEventSink.Detach;
begin
  FManager := nil;
end;

procedure TLazBleManagerEventSink.HandleBackendEvent(
  const AEvent: TLazBleBackendEvent);
begin
  if Assigned(FManager) then
    FManager.HandleBackendEvent(AEvent);
end;

constructor TBleCentralManager.Create(const ABackend: ILazBleBackend);
begin
  inherited Create;
  if not Assigned(ABackend) then
    raise EArgumentNilException.Create('ABackend');
  FBackend := ABackend;
  FSessions := TList.Create;
  FEventSinkObject := TLazBleManagerEventSink.Create(Self);
  FEventSink := FEventSinkObject;
  FBackend.SetEventSink(FEventSink);
  FState := lbcsIdle;
end;

destructor TBleCentralManager.Destroy;
var
  Index: Integer;
begin
  if Assigned(FEventSinkObject) then
    FEventSinkObject.Detach;
  if Assigned(FBackend) then
  begin
    FBackend.SetEventSink(nil);
    if FState <> lbcsShutdown then
      FBackend.BeginShutdown;
  end;
  for Index := FSessions.Count - 1 downto 0 do
    TObject(FSessions[Index]).Free;
  FSessions.Free;
  FBackend := nil;
  FEventSink := nil;
  FEventSinkObject := nil;
  inherited Destroy;
end;

function TBleCentralManager.SubmitCommand(
  const ACommand: TLazBleBackendCommand): TBleOperationId;
begin
  if not Assigned(FBackend) or
    (FState in [lbcsShuttingDown, lbcsShutdown]) then
    Exit(InvalidBleOperationId);
  Result := FBackend.Submit(ACommand);
end;

function TBleCentralManager.StartScan(const AAdapterId: string;
  const ATimeoutMs: Cardinal): TBleOperationId;
var
  Command: TLazBleBackendCommand;
begin
  Result := InvalidBleOperationId;
  if FState <> lbcsIdle then
    Exit;
  Command := Default(TLazBleBackendCommand);
  Command.Kind := lbckStartScan;
  Command.AdapterId := AAdapterId;
  Command.TimeoutMs := ATimeoutMs;
  Result := SubmitCommand(Command);
  if Result <> InvalidBleOperationId then
  begin
    FScanOperationId := Result;
    FState := lbcsScanning;
  end;
end;

function TBleCentralManager.CreateSession(
  const ADeviceId: string): TBleGattSession;
var
  Index: Integer;
begin
  Result := nil;
  if FState in [lbcsShuttingDown, lbcsShutdown] then
    Exit;
  for Index := 0 to FSessions.Count - 1 do
  begin
    Result := TBleGattSession(FSessions[Index]);
    if Result.DeviceId = ADeviceId then
      Exit;
  end;
  Result := TBleGattSession.Create(ADeviceId, @SubmitCommand,
    @CancelOperation);
  FSessions.Add(Result);
end;

function TBleCentralManager.BeginShutdown: TBleOperationId;
begin
  if FState = lbcsShutdown then
    Exit(FShutdownOperationId);
  if FState = lbcsShuttingDown then
    Exit(FShutdownOperationId);
  FState := lbcsShuttingDown;
  FShutdownOperationId := FBackend.BeginShutdown;
  Result := FShutdownOperationId;
end;

procedure TBleCentralManager.HandleBackendEvent(
  const AEvent: TLazBleBackendEvent);
var
  Index: Integer;
begin
  if FState = lbcsShutdown then
    Exit;

  if (AEvent.Kind = lbekScanResult) and
    (AEvent.OperationId = FScanOperationId) and Assigned(FOnScanResult) then
    FOnScanResult(Self, AEvent.DeviceId, AEvent.DeviceName, AEvent.Rssi);

  if (FState = lbcsShuttingDown) and
    (AEvent.Kind = lbekShutdownCompleted) and
    (AEvent.OperationId = FShutdownOperationId) then
  begin
    for Index := 0 to FSessions.Count - 1 do
      TBleGattSession(FSessions[Index]).HandleBackendShutdown;
    FBackend.SetEventSink(nil);
    FEventSinkObject.Detach;
    FState := lbcsShutdown;
    Exit;
  end;

  for Index := 0 to FSessions.Count - 1 do
    TBleGattSession(FSessions[Index]).HandleBackendEvent(AEvent);

  if LazBleBackendEventIsTerminal(AEvent) and
    (AEvent.OperationId = FScanOperationId) then
  begin
    FScanOperationId := InvalidBleOperationId;
    if FState = lbcsScanning then
      FState := lbcsIdle;
    if Assigned(FOnScanCompleted) then
      FOnScanCompleted(Self, AEvent.Kind = lbekOperationSucceeded,
        AEvent.ErrorCode, AEvent.ErrorMessage);
  end;
end;

end.
