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
  end;

  TFakeLazBleBackend = class(TInterfacedObject, ILazBleBackend)
  private
    FEventSink: ILazBleBackendEventSink;
    FNextOperationId: TBleOperationId;
    FCommands: array of TLazBleBackendCommand;
    FOperationIds: array of TBleOperationId;
    FOperations: array of TFakeLazBleOperation;
    FCancelledOperationIds: array of TBleOperationId;
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
    procedure SetEventSink(const AEventSink: ILazBleBackendEventSink);
    function Submit(const ACommand: TLazBleBackendCommand): TBleOperationId;
    procedure Cancel(const AOperationId: TBleOperationId);
    function BeginShutdown: TBleOperationId;
    procedure Emit(const AEvent: TLazBleBackendEvent);
    function EmitProgress(const AEvent: TLazBleBackendEvent): Boolean;
    function CompleteOperation(const AOperationId: TBleOperationId;
      const AEventKind: TLazBleBackendEventKind): Boolean;
    function CompleteShutdown: Boolean;
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

function TFakeLazBleBackend.AllocateOperationId: TBleOperationId;
begin
  Inc(FNextOperationId);
  Result := FNextOperationId;
end;

function TFakeLazBleBackend.FindOperation(
  const AOperationId: TBleOperationId): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(FOperations) do
    if FOperations[Index].OperationId = AOperationId then
      Exit(Index);
  Result := -1;
end;

function TFakeLazBleBackend.AllOperationsAreTerminal: Boolean;
var
  Operation: TFakeLazBleOperation;
begin
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
  Index := Length(FCancelledOperationIds);
  SetLength(FCancelledOperationIds, Index + 1);
  FCancelledOperationIds[Index] := AOperationId;
end;

procedure TFakeLazBleBackend.Deliver(const AEvent: TLazBleBackendEvent);
begin
  if Assigned(FEventSink) then
    FEventSink.HandleBackendEvent(AEvent);
end;

function TFakeLazBleBackend.GetCommand(
  const AIndex: Integer): TLazBleBackendCommand;
begin
  Result := FCommands[AIndex];
end;

function TFakeLazBleBackend.GetOperationId(
  const AIndex: Integer): TBleOperationId;
begin
  Result := FOperationIds[AIndex];
end;

function TFakeLazBleBackend.GetCancelledOperationId(
  const AIndex: Integer): TBleOperationId;
begin
  Result := FCancelledOperationIds[AIndex];
end;

procedure TFakeLazBleBackend.SetEventSink(
  const AEventSink: ILazBleBackendEventSink);
begin
  FEventSink := AEventSink;
end;

function TFakeLazBleBackend.Submit(
  const ACommand: TLazBleBackendCommand): TBleOperationId;
var
  Index: Integer;
begin
  if FShutdownStarted then
    Exit(InvalidBleOperationId);

  Result := AllocateOperationId;
  Index := Length(FCommands);
  SetLength(FCommands, Index + 1);
  SetLength(FOperationIds, Index + 1);
  SetLength(FOperations, Index + 1);
  FCommands[Index] := ACommand;
  FOperationIds[Index] := Result;
  FOperations[Index].OperationId := Result;
end;

procedure TFakeLazBleBackend.Cancel(const AOperationId: TBleOperationId);
var
  Index: Integer;
begin
  Index := FindOperation(AOperationId);
  if (Index < 0) or FOperations[Index].TerminalDelivered or
    FOperations[Index].CancellationRequested then
    Exit;

  FOperations[Index].CancellationRequested := True;
  RecordCancellation(AOperationId);
end;

function TFakeLazBleBackend.BeginShutdown: TBleOperationId;
var
  Index: Integer;
begin
  if FShutdownStarted then
    Exit(FShutdownOperationId);

  FShutdownStarted := True;
  FShutdownOperationId := AllocateOperationId;
  for Index := 0 to High(FOperations) do
    if not FOperations[Index].TerminalDelivered then
      Cancel(FOperations[Index].OperationId);
  Result := FShutdownOperationId;
end;

procedure TFakeLazBleBackend.Emit(const AEvent: TLazBleBackendEvent);
begin
  EmitProgress(AEvent);
end;

function TFakeLazBleBackend.EmitProgress(
  const AEvent: TLazBleBackendEvent): Boolean;
var
  Index: Integer;
begin
  Result := not FShutdownCompleted and
    not LazBleBackendEventIsTerminal(AEvent);
  if Result and (AEvent.OperationId <> InvalidBleOperationId) then
  begin
    Index := FindOperation(AEvent.OperationId);
    Result := (Index >= 0) and not FOperations[Index].TerminalDelivered;
  end;
  if Result then
    Deliver(AEvent);
end;

function TFakeLazBleBackend.CompleteOperation(
  const AOperationId: TBleOperationId;
  const AEventKind: TLazBleBackendEventKind): Boolean;
var
  BackendEvent: TLazBleBackendEvent;
  Index: Integer;
begin
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

  FOperations[Index].TerminalDelivered := True;
  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := AEventKind;
  BackendEvent.OperationId := AOperationId;
  Deliver(BackendEvent);
  Result := True;
end;

function TFakeLazBleBackend.CompleteShutdown: Boolean;
var
  BackendEvent: TLazBleBackendEvent;
begin
  Result := FShutdownStarted and not FShutdownCompleted and
    AllOperationsAreTerminal;
  if not Result then
    Exit;

  FShutdownCompleted := True;
  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := lbekShutdownCompleted;
  BackendEvent.OperationId := FShutdownOperationId;
  Deliver(BackendEvent);
end;

function TFakeLazBleBackend.CancellationWasRequested(
  const AOperationId: TBleOperationId): Boolean;
var
  Index: Integer;
begin
  Index := FindOperation(AOperationId);
  Result := (Index >= 0) and FOperations[Index].CancellationRequested;
end;

function TFakeLazBleBackend.HasEventSink: Boolean;
begin
  Result := Assigned(FEventSink);
end;

function TFakeLazBleBackend.CommandCount: Integer;
begin
  Result := Length(FCommands);
end;

function TFakeLazBleBackend.CancelledOperationCount: Integer;
begin
  Result := Length(FCancelledOperationIds);
end;

end.
