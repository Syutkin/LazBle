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

  TLazBleScanCompletedEvent = procedure(Sender: TObject;
    const AOutcome: TLazBleBackendEventKind; const AErrorCode: Integer;
    const AErrorMessage: string) of object;
  TLazBleCentralStateChangedEvent = procedure(Sender: TObject;
    const AState: TLazBleCentralState) of object;
  TLazBleAvailabilityCompletedEvent = procedure(Sender: TObject;
    const AOutcome: TLazBleBackendEventKind; const AErrorCode: Integer;
    const AErrorMessage: string) of object;
  TLazBleAvailabilityResultEvent = procedure(Sender: TObject;
    const AEvent: TLazBleBackendEvent) of object;

  TBleCentralManager = class;

  TLazBleManagerEventSink = class(TInterfacedObject,
    ILazBleBackendEventSink)
  private
    FManager: TBleCentralManager;
  public
    constructor Create(const AManager: TBleCentralManager);
    destructor Destroy; override;
    procedure Detach;
    procedure HandleBackendEvent(const AEvent: TLazBleBackendEvent);
  end;

  { Coordinates scanning, availability checks and GATT sessions for one
    backend. Applications normally use TLazBle rather than this lower layer. }
  TBleCentralManager = class
  private
    FBackend: ILazBleBackend;
    FEventSink: ILazBleBackendEventSink;
    FEventSinkObject: TLazBleManagerEventSink;
    FSessions: TList;
    FState: TLazBleCentralState;
    FScanOperationId: TBleOperationId;
    FAvailabilityOperationId: TBleOperationId;
    FShutdownOperationId: TBleOperationId;
    FShutdownFailed: Boolean;
    FShutdownErrorCode: Integer;
    FShutdownErrorMessage: string;
    FOnScanResult: TLazBleScanResultEvent;
    FOnScanCompleted: TLazBleScanCompletedEvent;
    FOnAvailabilityResult: TLazBleAvailabilityResultEvent;
    FOnAvailabilityCompleted: TLazBleAvailabilityCompletedEvent;
    FOnStateChanged: TLazBleCentralStateChangedEvent;
    procedure SetState(const AState: TLazBleCentralState);
    function SubmitCommand(
      const ACommand: TLazBleBackendCommand): TBleOperationId;
    procedure CancelOperation(const AOperationId: TBleOperationId);
    procedure HandleBackendEvent(const AEvent: TLazBleBackendEvent);
  protected
    procedure DetachBackendEvents;
  public
    constructor Create(const ABackend: ILazBleBackend);
    destructor Destroy; override;
    { Submit one scan and receive results through OnScanResult. }
    function StartScan(const AAdapterId: string;
      const ATimeoutMs: Cardinal): TBleOperationId;
    procedure CancelScan;
    { Query adapter availability; OnAvailabilityResult forwards its backend event. }
    function CheckAvailability(const AAdapterId: string): TBleOperationId;
    procedure CancelAvailabilityCheck;
    { Create a session managed by this central manager. }
    function CreateSession(const ADeviceId: string): TBleGattSession;
    function BeginShutdown: TBleOperationId;
    property ShutdownFailed: Boolean read FShutdownFailed;
    property ShutdownErrorCode: Integer read FShutdownErrorCode;
    property ShutdownErrorMessage: string read FShutdownErrorMessage;
    property State: TLazBleCentralState read FState;
    property OnScanResult: TLazBleScanResultEvent read FOnScanResult
      write FOnScanResult;
    property OnScanCompleted: TLazBleScanCompletedEvent read FOnScanCompleted
      write FOnScanCompleted;
    property OnAvailabilityResult: TLazBleAvailabilityResultEvent
      read FOnAvailabilityResult write FOnAvailabilityResult;
    property OnAvailabilityCompleted: TLazBleAvailabilityCompletedEvent
      read FOnAvailabilityCompleted write FOnAvailabilityCompleted;
    property OnStateChanged: TLazBleCentralStateChangedEvent
      read FOnStateChanged write FOnStateChanged;
  end;

implementation

type
  TBleGattSessionAccess = class(TBleGattSession)
  public
    constructor CreateInternal(const ADeviceId: string;
      const ASubmitCommand: TLazBleSubmitCommand;
      const ACancelOperation: TLazBleCancelOperation);
    procedure HandleEvent(const AEvent: TLazBleBackendEvent);
    procedure HandleShutdown;
    procedure PrepareShutdownInternal;
  end;

constructor TBleGattSessionAccess.CreateInternal(const ADeviceId: string;
  const ASubmitCommand: TLazBleSubmitCommand;
  const ACancelOperation: TLazBleCancelOperation);
begin
  inherited Create(ADeviceId, ASubmitCommand, ACancelOperation);
end;

procedure TBleGattSessionAccess.HandleEvent(
  const AEvent: TLazBleBackendEvent);
begin
  LazBleRequireMainThread;
  HandleBackendEvent(AEvent);
end;

procedure TBleGattSessionAccess.HandleShutdown;
begin
  LazBleRequireMainThread;
  HandleBackendShutdown;
end;

procedure TBleGattSessionAccess.PrepareShutdownInternal;
begin
  PrepareShutdown;
end;

procedure TBleCentralManager.SetState(const AState: TLazBleCentralState);
begin
  LazBleRequireMainThread;
  if FState = AState then
    Exit;
  FState := AState;
  if Assigned(FOnStateChanged) then
    FOnStateChanged(Self, FState);
end;

constructor TLazBleManagerEventSink.Create(
  const AManager: TBleCentralManager);
begin
  inherited Create;
  FManager := AManager;
end;

destructor TLazBleManagerEventSink.Destroy;
begin
  Detach;
  inherited Destroy;
end;

procedure TBleCentralManager.CancelOperation(
  const AOperationId: TBleOperationId);
begin
  LazBleRequireMainThread;
  if Assigned(FBackend) and
    not (FState in [lbcsShuttingDown, lbcsShutdown]) then
    FBackend.Cancel(AOperationId);
end;

procedure TLazBleManagerEventSink.Detach;
begin
  LazBleRequireMainThread;
  LazBleRequireMainThread;
  FManager := nil;
end;

procedure TLazBleManagerEventSink.HandleBackendEvent(
  const AEvent: TLazBleBackendEvent);
begin
  LazBleRequireMainThread;
  LazBleRequireMainThread;
  if Assigned(FManager) then FManager.HandleBackendEvent(AEvent);
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
  DetachBackendEvents;
  if Assigned(FBackend) then
  begin
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

procedure TBleCentralManager.DetachBackendEvents;
begin
  LazBleRequireMainThread;
  if Assigned(FBackend) then
    FBackend.SetEventSink(nil);
  if Assigned(FEventSinkObject) then
    FEventSinkObject.Detach;
end;

function TBleCentralManager.SubmitCommand(
  const ACommand: TLazBleBackendCommand): TBleOperationId;
begin
  LazBleRequireMainThread;
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
  LazBleRequireMainThread;
  Result := InvalidBleOperationId;
  if (FState <> lbcsIdle) or
    (FAvailabilityOperationId <> InvalidBleOperationId) then
    Exit;
  Command := Default(TLazBleBackendCommand);
  Command.Kind := lbckStartScan;
  Command.AdapterId := AAdapterId;
  Command.TimeoutMs := ATimeoutMs;
  Result := SubmitCommand(Command);
  if Result <> InvalidBleOperationId then
  begin
    FScanOperationId := Result;
    SetState(lbcsScanning);
  end;
end;

function TBleCentralManager.CheckAvailability(
  const AAdapterId: string): TBleOperationId;
var
  Command: TLazBleBackendCommand;
begin
  LazBleRequireMainThread;
  Result := InvalidBleOperationId;
  if (FState <> lbcsIdle) or
    (FAvailabilityOperationId <> InvalidBleOperationId) then
    Exit;
  Command := Default(TLazBleBackendCommand);
  Command.Kind := lbckCheckAvailability;
  Command.AdapterId := AAdapterId;
  Result := SubmitCommand(Command);
  if Result <> InvalidBleOperationId then
    FAvailabilityOperationId := Result;
end;

procedure TBleCentralManager.CancelAvailabilityCheck;
begin
  LazBleRequireMainThread;
  if FAvailabilityOperationId <> InvalidBleOperationId then
    CancelOperation(FAvailabilityOperationId);
end;

procedure TBleCentralManager.CancelScan;
begin
  LazBleRequireMainThread;
  if (FState = lbcsScanning) and
    (FScanOperationId <> InvalidBleOperationId) then
    CancelOperation(FScanOperationId);
end;

function TBleCentralManager.CreateSession(
  const ADeviceId: string): TBleGattSession;
var
  Index: Integer;
begin
  LazBleRequireMainThread;
  Result := nil;
  if FState in [lbcsShuttingDown, lbcsShutdown] then
    Exit;
  for Index := 0 to FSessions.Count - 1 do
  begin
    Result := TBleGattSession(FSessions[Index]);
    if Result.DeviceId = ADeviceId then
      Exit;
  end;
  Result := TBleGattSessionAccess.CreateInternal(ADeviceId, @SubmitCommand,
    @CancelOperation);
  FSessions.Add(Result);
end;

function TBleCentralManager.BeginShutdown: TBleOperationId;
var I: Integer;
begin
  LazBleRequireMainThread;
  if FState = lbcsShutdown then
    Exit(FShutdownOperationId);
  if FState = lbcsShuttingDown then
    Exit(FShutdownOperationId);
  SetState(lbcsShuttingDown);
  for I := 0 to FSessions.Count - 1 do
    TBleGattSessionAccess(FSessions[I]).PrepareShutdownInternal;
  FShutdownOperationId := FBackend.BeginShutdown;
  Result := FShutdownOperationId;
end;

procedure TBleCentralManager.HandleBackendEvent(
  const AEvent: TLazBleBackendEvent);
var
  Index: Integer;
begin
  LazBleRequireMainThread;
  if FState = lbcsShutdown then
    Exit;

  if (AEvent.Kind = lbekScanResult) and
    (AEvent.OperationId = FScanOperationId) and Assigned(FOnScanResult) then
    FOnScanResult(Self, AEvent.DeviceId, AEvent.DeviceName, AEvent.Rssi);

  if (AEvent.Kind = lbekAvailabilityResult) and
    (AEvent.OperationId = FAvailabilityOperationId) and
    Assigned(FOnAvailabilityResult) then
    FOnAvailabilityResult(Self, AEvent);

  if (FState = lbcsShuttingDown) and
    (AEvent.Kind = lbekShutdownCompleted) and
    (AEvent.OperationId = FShutdownOperationId) then
  begin
    FShutdownFailed := AEvent.ShutdownFailed;
    FShutdownErrorCode := AEvent.ErrorCode;
    FShutdownErrorMessage := AEvent.ErrorMessage;
    for Index := 0 to FSessions.Count - 1 do
      TBleGattSessionAccess(FSessions[Index]).HandleShutdown;
    FBackend.SetEventSink(nil);
    FEventSinkObject.Detach;
    SetState(lbcsShutdown);
    Exit;
  end;

  for Index := 0 to FSessions.Count - 1 do
    TBleGattSessionAccess(FSessions[Index]).HandleEvent(AEvent);

  if LazBleBackendEventIsTerminal(AEvent) and
    (AEvent.OperationId = FScanOperationId) then
  begin
    FScanOperationId := InvalidBleOperationId;
    if FState = lbcsScanning then
      SetState(lbcsIdle);
    if Assigned(FOnScanCompleted) then
      FOnScanCompleted(Self, AEvent.Kind,
        AEvent.ErrorCode, AEvent.ErrorMessage);
  end;

  if LazBleBackendEventIsTerminal(AEvent) and
    (AEvent.OperationId = FAvailabilityOperationId) then
  begin
    FAvailabilityOperationId := InvalidBleOperationId;
    if Assigned(FOnAvailabilityCompleted) then
      FOnAvailabilityCompleted(Self,
        AEvent.Kind, AEvent.ErrorCode,
        AEvent.ErrorMessage);
  end;
end;

end.
