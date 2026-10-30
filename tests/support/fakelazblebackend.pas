unit FakeLazBleBackend;

{$mode objfpc}{$H+}

interface

uses
  LazBleTypes,
  LazBleBackend;

type
  TFakeLazBleOperation = record
    OperationId: TBleOperationId;
    CancellationRequested: Boolean;
    TerminalDelivered: Boolean;
    Completion: ILazBleRequestCompletion;
    ResultData: TLazBleRequestResult;
    Values: ILazBleValueSink;
    Scan: ILazBleScanSink;
    Link: ILazBleLinkObserver;
  end;

  TFakeLazBleBackend = class(TInterfacedObject, ILazBleBackend)
  private
    FEventSink: ILazBleBackendEventSink;
    FNextOperationId: TBleOperationId;
    FCommands: array of TLazBleBackendCommand;
    FOperationIds: array of TBleOperationId;
    FOperations: array of TFakeLazBleOperation;
    FCancelledOperationIds: array of TBleOperationId;
    FShutdownCompletion: ILazBleRequestCompletion;
    FShutdownOperationId: TBleOperationId;
    FShutdownStarted: Boolean;
    FShutdownCompleted: Boolean;
    function AllocateOperationId: TBleOperationId;
    function FindOperation(const AOperationId: TBleOperationId): Integer;
    function AllOperationsAreTerminal: Boolean;
    procedure RecordCancellation(const AOperationId: TBleOperationId);
    procedure Deliver(const AEvent: TLazBleBackendEvent);
    function GetCommand(const AIndex: Integer): TLazBleBackendCommand;
    function GetOperationId(const AIndex: Integer): TBleOperationId;
    function GetCancelledOperationId(const AIndex: Integer): TBleOperationId;
  public
    function GetBackendName: string;
    procedure SetEventSink(const AEventSink: ILazBleBackendEventSink);
    function Submit(const ACommand: TLazBleBackendCommand;
      const ACompletion: ILazBleRequestCompletion = nil;
      const AValues: ILazBleValueSink = nil;
      const AScan: ILazBleScanSink = nil;
      const ALink: ILazBleLinkObserver = nil): TBleOperationId;
    procedure Cancel(const AOperationId: TBleOperationId);
    function BeginShutdown(const ACompletion: ILazBleRequestCompletion = nil): TBleOperationId;
    procedure Emit(const AEvent: TLazBleBackendEvent);
    function EmitProgress(const AEvent: TLazBleBackendEvent): Boolean;
    function CompleteOperation(const AOperationId: TBleOperationId;
      const AEventKind: TLazBleBackendEventKind;
      const AErrorCode: Integer = 0;
      const AErrorMessage: string = ''): Boolean;
    function FinishRequest(const AOperationId: TBleOperationId;
      const AResult: TLazBleRequestResult): Boolean;
    function CompleteShutdown(const AErrorCode: Integer = 0;
      const AErrorMessage: string = ''; const AFailed: Boolean = False): Boolean;
    function CancellationWasRequested(
      const AOperationId: TBleOperationId): Boolean;
    function HasEventSink: Boolean;
    function CommandCount: Integer;
    function CancelledOperationCount: Integer;
    property Commands[const AIndex: Integer]: TLazBleBackendCommand
      read GetCommand;
    property OperationIds[const AIndex: Integer]: TBleOperationId
      read GetOperationId;
    property CancelledOperationIds[const AIndex: Integer]: TBleOperationId
      read GetCancelledOperationId;
    property ShutdownOperationId: TBleOperationId read FShutdownOperationId;
  end;

implementation

function TFakeLazBleBackend.GetBackendName: string;
begin
  LazBleRequireMainThread;
  Result := 'FakeBLE';
end;

function TFakeLazBleBackend.AllocateOperationId: TBleOperationId;
begin
  LazBleRequireMainThread;
  Inc(FNextOperationId);
  Result := FNextOperationId;
end;

function TFakeLazBleBackend.FindOperation(
  const AOperationId: TBleOperationId): Integer;
var
  Index: Integer;
begin
  LazBleRequireMainThread;
  for Index := 0 to High(FOperations) do
    if FOperations[Index].OperationId = AOperationId then
      Exit(Index);
  Result := -1;
end;

function TFakeLazBleBackend.AllOperationsAreTerminal: Boolean;
var
  Operation: TFakeLazBleOperation;
begin
  LazBleRequireMainThread;
  for Operation in FOperations do
    if not Operation.TerminalDelivered then
      Exit(False);
  Result := True;
end;

procedure TFakeLazBleBackend.RecordCancellation(
  const AOperationId: TBleOperationId);
var
  Index: Integer;
begin
  LazBleRequireMainThread;
  Index := Length(FCancelledOperationIds);
  SetLength(FCancelledOperationIds, Index + 1);
  FCancelledOperationIds[Index] := AOperationId;
end;

procedure TFakeLazBleBackend.Deliver(const AEvent: TLazBleBackendEvent);
begin
  LazBleRequireMainThread;
  if Assigned(FEventSink) then
    FEventSink.HandleBackendEvent(AEvent);
end;

function TFakeLazBleBackend.GetCommand(
  const AIndex: Integer): TLazBleBackendCommand;
begin
  LazBleRequireMainThread;
  Result := FCommands[AIndex];
end;

function TFakeLazBleBackend.GetOperationId(
  const AIndex: Integer): TBleOperationId;
begin
  LazBleRequireMainThread;
  Result := FOperationIds[AIndex];
end;

function TFakeLazBleBackend.GetCancelledOperationId(
  const AIndex: Integer): TBleOperationId;
begin
  LazBleRequireMainThread;
  Result := FCancelledOperationIds[AIndex];
end;

procedure TFakeLazBleBackend.SetEventSink(
  const AEventSink: ILazBleBackendEventSink);
begin
  LazBleRequireMainThread;
  FEventSink := AEventSink;
end;

function TFakeLazBleBackend.Submit(
  const ACommand: TLazBleBackendCommand;
  const ACompletion: ILazBleRequestCompletion;
  const AValues: ILazBleValueSink; const AScan: ILazBleScanSink;
  const ALink: ILazBleLinkObserver): TBleOperationId;
var
  Index: Integer;
begin
  LazBleRequireMainThread;
  if FShutdownStarted then
    Exit(InvalidBleOperationId);

  Result := AllocateOperationId;
  Index := Length(FCommands);
  SetLength(FCommands, Index + 1);
  SetLength(FOperationIds, Index + 1);
  SetLength(FOperations, Index + 1);
  FCommands[Index] := ACommand;
  FCommands[Index].Value := Copy(ACommand.Value);
  FOperationIds[Index] := Result;
  FOperations[Index].OperationId := Result;
  FOperations[Index].Completion := ACompletion;
  FOperations[Index].Values := AValues;
  FOperations[Index].Scan := AScan;
  FOperations[Index].Link := ALink;
end;

procedure TFakeLazBleBackend.Cancel(const AOperationId: TBleOperationId);
var
  Index: Integer;
begin
  LazBleRequireMainThread;
  Index := FindOperation(AOperationId);
  if (Index < 0) or FOperations[Index].TerminalDelivered or
    FOperations[Index].CancellationRequested then
    Exit;

  FOperations[Index].CancellationRequested := True;
  RecordCancellation(AOperationId);
end;

function TFakeLazBleBackend.BeginShutdown(const ACompletion: ILazBleRequestCompletion): TBleOperationId;
var
  Index: Integer;
begin
  LazBleRequireMainThread;
  if FShutdownStarted then
    Exit(FShutdownOperationId);

  FShutdownStarted := True;
  FShutdownOperationId := AllocateOperationId;
  FShutdownCompletion := ACompletion;
  for Index := 0 to High(FOperations) do
    if not FOperations[Index].TerminalDelivered then
      Cancel(FOperations[Index].OperationId);
  Result := FShutdownOperationId;
end;

procedure TFakeLazBleBackend.Emit(const AEvent: TLazBleBackendEvent);
begin
  LazBleRequireMainThread;
  EmitProgress(AEvent);
end;

function TFakeLazBleBackend.EmitProgress(
  const AEvent: TLazBleBackendEvent): Boolean;
var
  Index: Integer;
  Device: TBleDeviceInfo;
begin
  LazBleRequireMainThread;
  Index := FindOperation(AEvent.OperationId);
  Result := not FShutdownCompleted and
    not LazBleBackendEventIsTerminal(AEvent);
  if Result and (AEvent.OperationId <> InvalidBleOperationId) and
    not (AEvent.Kind in [lbekConnected, lbekDisconnected]) then
  begin
    Index := FindOperation(AEvent.OperationId);
    Result := (Index >= 0) and not FOperations[Index].TerminalDelivered;
  end;
  if Result then
  begin
    if AEvent.Kind in [lbekConnected, lbekDisconnected] then
      for Index := High(FOperations) downto 0 do
        if (FOperations[Index].Link <> nil) and
          (FCommands[Index].DeviceId = AEvent.DeviceId) then
        begin
          FOperations[Index].Link.LinkChanged(AEvent.Kind = lbekConnected,
            AEvent.Generation);
          Exit(True);
        end;
    Index := FindOperation(AEvent.OperationId);
    if (AEvent.Kind = lbekScanResult) and (Index >= 0) and
      (FOperations[Index].Scan <> nil) then
    begin
      Device.DeviceId := AEvent.DeviceId; Device.DeviceName := AEvent.DeviceName;
      Device.Rssi := AEvent.Rssi;
      FOperations[Index].Scan.ReceiveScanResult(Device);
      Exit(True);
    end;
    if AEvent.Kind = lbekNotification then
      for Index := 0 to High(FOperations) do
        if (FOperations[Index].Values <> nil) and
          (FOperations[Index].ResultData.SubscriptionId = AEvent.SubscriptionId) then
        begin
          FOperations[Index].Values.ReceiveValue(AEvent.Value);
          Exit(True);
        end;
    if (Index >= 0) and
      (FOperations[Index].Completion <> nil) and
      (AEvent.Kind in [lbekReadResult, lbekServicesDiscovered,
        lbekAvailabilityResult, lbekSubscribed]) then
      with FOperations[Index].ResultData do
      begin
        Value := AEvent.Value;
        Services := AEvent.Services;
        SubscriptionId := AEvent.SubscriptionId;
        if AEvent.Available then Availability := lbaAvailable else Availability := lbaUnavailable;
        BackendName := AEvent.BackendName;
        BackendVersion := AEvent.BackendVersion;
        AdapterId := AEvent.AdapterId;
      end
    else Deliver(AEvent);
  end;
end;

function TFakeLazBleBackend.FinishRequest(const AOperationId: TBleOperationId;
  const AResult: TLazBleRequestResult): Boolean;
var Index: Integer; Completion: ILazBleRequestCompletion;
begin
  LazBleRequireMainThread;
  Index := FindOperation(AOperationId);
  Result := not FShutdownCompleted and (Index >= 0);
  if not Result then Exit;
  Result := not FOperations[Index].TerminalDelivered and
    (FOperations[Index].Completion <> nil);
  if not Result then Exit;
  FOperations[Index].TerminalDelivered := True;
  FOperations[Index].ResultData := AResult;
  Completion := FOperations[Index].Completion;
  FOperations[Index].Completion := nil;
  Completion.CompleteRequest(AResult);
end;

function TFakeLazBleBackend.CompleteOperation(
  const AOperationId: TBleOperationId;
  const AEventKind: TLazBleBackendEventKind; const AErrorCode: Integer;
  const AErrorMessage: string): Boolean;
var
  BackendEvent: TLazBleBackendEvent;
  Index: Integer;
  ResultData: TLazBleRequestResult;
begin
  LazBleRequireMainThread;
  Result := False;
  if FShutdownCompleted or not (AEventKind in [
    lbekOperationSucceeded,
    lbekOperationFailed,
    lbekOperationCancelled
  ]) then
    Exit;

  Index := FindOperation(AOperationId);
  if (Index < 0) or FOperations[Index].TerminalDelivered then
    Exit;

  if FOperations[Index].Completion <> nil then
  begin
    ResultData := FOperations[Index].ResultData;
    case AEventKind of
      lbekOperationSucceeded: ResultData.Status := lbrsSucceeded;
      lbekOperationFailed: ResultData.Status := lbrsFailed;
      lbekOperationCancelled: ResultData.Status := lbrsCancelled;
    end;
    ResultData.ErrorCode := AErrorCode;
    ResultData.ErrorMessage := AErrorMessage;
    Exit(FinishRequest(AOperationId, ResultData));
  end;
  FOperations[Index].TerminalDelivered := True;
  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := AEventKind;
  BackendEvent.OperationId := AOperationId;
  BackendEvent.Generation := FCommands[Index].Generation;
  BackendEvent.DeviceId := FCommands[Index].DeviceId;
  BackendEvent.ErrorCode := AErrorCode;
  BackendEvent.ErrorMessage := AErrorMessage;
  Deliver(BackendEvent);
  Result := True;
end;

function TFakeLazBleBackend.CompleteShutdown(const AErrorCode: Integer;
  const AErrorMessage: string; const AFailed: Boolean): Boolean;
var
  BackendEvent: TLazBleBackendEvent;
  Completion: ILazBleRequestCompletion;
  R: TLazBleRequestResult;
  I: Integer;
begin
  LazBleRequireMainThread;
  Result := FShutdownStarted and not FShutdownCompleted and
    AllOperationsAreTerminal;
  if not Result then
    Exit;

  FShutdownCompleted := True;
  Completion := FShutdownCompletion;
  FShutdownCompletion := nil;
  if Completion <> nil then
  begin
    for I := 0 to High(FOperations) do
    begin
      FOperations[I].Values := nil;
      FOperations[I].Scan := nil;
      FOperations[I].Link := nil;
    end;
    R := Default(TLazBleRequestResult);
    R.Status := lbrsSucceeded;
    if AFailed or (AErrorCode <> 0) or (AErrorMessage <> '') then R.Status := lbrsFailed;
    R.ErrorCode := AErrorCode; R.ErrorMessage := AErrorMessage;
    Completion.CompleteRequest(R);
    Exit;
  end;
  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := lbekShutdownCompleted;
  BackendEvent.OperationId := FShutdownOperationId;
  BackendEvent.ShutdownFailed := AFailed or (AErrorCode <> 0) or (AErrorMessage <> '');
  BackendEvent.ErrorCode := AErrorCode;
  BackendEvent.ErrorMessage := AErrorMessage;
  Deliver(BackendEvent);
end;

function TFakeLazBleBackend.CancellationWasRequested(
  const AOperationId: TBleOperationId): Boolean;
var
  Index: Integer;
begin
  LazBleRequireMainThread;
  Index := FindOperation(AOperationId);
  Result := (Index >= 0) and FOperations[Index].CancellationRequested;
end;

function TFakeLazBleBackend.HasEventSink: Boolean;
begin
  LazBleRequireMainThread;
  Result := Assigned(FEventSink);
end;

function TFakeLazBleBackend.CommandCount: Integer;
begin
  LazBleRequireMainThread;
  Result := Length(FCommands);
end;

function TFakeLazBleBackend.CancelledOperationCount: Integer;
begin
  LazBleRequireMainThread;
  Result := Length(FCancelledOperationIds);
end;

end.
