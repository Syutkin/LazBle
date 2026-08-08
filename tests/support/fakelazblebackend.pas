unit FakeLazBleBackend;

{$mode objfpc}{$H+}

interface

uses
  LazBleTypes,
  LazBleBackend;

type
  TFakeLazBleBackend = class(TInterfacedObject, ILazBleBackend)
  private
    FEventSink: ILazBleBackendEventSink;
    FNextOperationId: TBleOperationId;
    FCommands: array of TLazBleBackendCommand;
    FOperationIds: array of TBleOperationId;
    FCancelledOperationIds: array of TBleOperationId;
    FShutdownOperationId: TBleOperationId;
    function AllocateOperationId: TBleOperationId;
    function GetCommand(const AIndex: Integer): TLazBleBackendCommand;
    function GetOperationId(const AIndex: Integer): TBleOperationId;
    function GetCancelledOperationId(const AIndex: Integer): TBleOperationId;
  public
    procedure SetEventSink(const AEventSink: ILazBleBackendEventSink);
    function Submit(const ACommand: TLazBleBackendCommand): TBleOperationId;
    procedure Cancel(const AOperationId: TBleOperationId);
    function BeginShutdown: TBleOperationId;
    procedure Emit(const AEvent: TLazBleBackendEvent);
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
  Result := AllocateOperationId;
  Index := Length(FCommands);
  SetLength(FCommands, Index + 1);
  SetLength(FOperationIds, Index + 1);
  FCommands[Index] := ACommand;
  FOperationIds[Index] := Result;
end;

procedure TFakeLazBleBackend.Cancel(const AOperationId: TBleOperationId);
var
  Index: Integer;
begin
  Index := Length(FCancelledOperationIds);
  SetLength(FCancelledOperationIds, Index + 1);
  FCancelledOperationIds[Index] := AOperationId;
end;

function TFakeLazBleBackend.BeginShutdown: TBleOperationId;
begin
  FShutdownOperationId := AllocateOperationId;
  Result := FShutdownOperationId;
end;

procedure TFakeLazBleBackend.Emit(const AEvent: TLazBleBackendEvent);
begin
  if Assigned(FEventSink) then
    FEventSink.HandleBackendEvent(AEvent);
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
