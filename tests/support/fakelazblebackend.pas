unit FakeLazBleBackend;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, LazBleTypes,
  LazBleBackend;

type
  { Scenario fixtures and observations only; runtime requests use addressed completion. }
  TLazBleBackendEventKind = (
    lbekScanStarted,
    lbekScanResult,
    lbekScanStopped,
    lbekConnected,
    lbekDisconnected,
    lbekServicesDiscovered,
    lbekReadResult,
    lbekWriteCompleted,
    lbekSubscribed,
    lbekNotification,
    lbekUnsubscribed,
    lbekAvailabilityResult,
    lbekOperationSucceeded,
    lbekOperationFailed,
    lbekOperationCancelled,
    lbekShutdownCompleted
  );

  TLazBleBackendEvent = record
    Kind: TLazBleBackendEventKind;
    OperationId: TBleOperationId;
    SubscriptionId: TBleSubscriptionId;
    Generation: QWord;
    BackendName: string;
    BackendVersion: string;
    AdapterId: string;
    DeviceId: string;
    DeviceName: string;
    ServiceUuid: string;
    CharacteristicUuid: string;
    DescriptorUuid: string;
    Rssi: SmallInt;
    Available: Boolean;
    Value: TBytes;
    { Explicit flag for ShutdownCompleted: native error 0/empty text is valid. }
    ShutdownFailed: Boolean;
    ErrorCode: Integer;
    ErrorMessage: string;
    Services: TLazBleGattServices;
  end;

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
    function GetCommand(const AIndex: Integer): TLazBleBackendCommand;
    function GetOperationId(const AIndex: Integer): TBleOperationId;
    function GetCancelledOperationId(const AIndex: Integer): TBleOperationId;
  public
    function GetBackendName: string;
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
    function CommandCount: Integer;
    function CancelledOperationCount: Integer;
    property Commands[const AIndex: Integer]: TLazBleBackendCommand
      read GetCommand;
    property OperationIds[const AIndex: Integer]: TBleOperationId
      read GetOperationId;
    property CancelledOperationIds[const AIndex: Integer]: TBleOperationId
      read GetCancelledOperationId;
    property ShutdownStarted: Boolean read FShutdownStarted;
    property ShutdownCompleted: Boolean read FShutdownCompleted;
    property ShutdownOperationId: TBleOperationId read FShutdownOperationId;
  end;

function LazBleBackendEventIsTerminal(const AEvent: TLazBleBackendEvent): Boolean;

implementation

function LazBleBackendEventIsTerminal(
  const AEvent: TLazBleBackendEvent): Boolean;
begin
  Result := AEvent.Kind in [
    lbekOperationSucceeded,
    lbekOperationFailed,
    lbekOperationCancelled,
    lbekShutdownCompleted
  ];
end;


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

function TFakeLazBleBackend.Submit(
  const ACommand: TLazBleBackendCommand;
  const ACompletion: ILazBleRequestCompletion;
  const AValues: ILazBleValueSink; const AScan: ILazBleScanSink;
  const ALink: ILazBleLinkObserver): TBleOperationId;
var
  Index: Integer;
begin
  LazBleRequireMainThread;
  if FShutdownStarted or (ACompletion = nil) then
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
    Index := FindOperation(AEvent.OperationId);
    if (AEvent.Kind in [lbekReadResult, lbekServicesDiscovered,
      lbekAvailabilityResult, lbekSubscribed]) and (Index >= 0) and
      (FOperations[Index].Completion <> nil) then
      with FOperations[Index].ResultData do
      begin
        Value := AEvent.Value;
        Services := AEvent.Services;
        SubscriptionId := AEvent.SubscriptionId;
        if AEvent.Available then Availability := lbaAvailable else Availability := lbaUnavailable;
        BackendName := AEvent.BackendName;
        BackendVersion := AEvent.BackendVersion;
        AdapterId := AEvent.AdapterId;
      end;
  end;
end;

function TFakeLazBleBackend.FinishRequest(const AOperationId: TBleOperationId;
  const AResult: TLazBleRequestResult): Boolean;
var Index, I: Integer; Completion: ILazBleRequestCompletion;
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
  try
    Completion.CompleteRequest(AResult);
  finally
    FOperations[Index].Scan := nil;
    if (FCommands[Index].Kind = lbckSubscribe) and (AResult.Status <> lbrsSucceeded) then
      FOperations[Index].Values := nil;
    if FCommands[Index].Kind = lbckUnsubscribe then
      for I := 0 to High(FOperations) do
        if FOperations[I].ResultData.SubscriptionId = FCommands[Index].SubscriptionId then
          FOperations[I].Values := nil;
  end;
end;

function TFakeLazBleBackend.CompleteOperation(const AOperationId: TBleOperationId;
  const AEventKind: TLazBleBackendEventKind; const AErrorCode: Integer;
  const AErrorMessage: string): Boolean;
var Index: Integer; R: TLazBleRequestResult;
begin
  LazBleRequireMainThread;
  Index := FindOperation(AOperationId);
  if (Index < 0) or FShutdownCompleted then Exit(False);
  R := FOperations[Index].ResultData;
  case AEventKind of
    lbekOperationSucceeded: R.Status := lbrsSucceeded;
    lbekOperationFailed: R.Status := lbrsFailed;
    lbekOperationCancelled: R.Status := lbrsCancelled;
    else Exit(False);
  end;
  R.ErrorCode := AErrorCode; R.ErrorMessage := AErrorMessage;
  Result := FinishRequest(AOperationId, R);
end;

function TFakeLazBleBackend.CompleteShutdown(const AErrorCode: Integer;
  const AErrorMessage: string; const AFailed: Boolean): Boolean;
var Completion: ILazBleRequestCompletion; R: TLazBleRequestResult; I: Integer;
begin
  LazBleRequireMainThread;
  Result := FShutdownStarted and not FShutdownCompleted and AllOperationsAreTerminal;
  if not Result then Exit;
  FShutdownCompleted := True;
  Completion := FShutdownCompletion; FShutdownCompletion := nil;
  for I := 0 to High(FOperations) do
  begin
    FOperations[I].Values := nil; FOperations[I].Scan := nil; FOperations[I].Link := nil;
  end;
  R := Default(TLazBleRequestResult); R.Status := lbrsSucceeded;
  if AFailed or (AErrorCode <> 0) or (AErrorMessage <> '') then R.Status := lbrsFailed;
  R.ErrorCode := AErrorCode; R.ErrorMessage := AErrorMessage;
  if Completion <> nil then Completion.CompleteRequest(R);
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
