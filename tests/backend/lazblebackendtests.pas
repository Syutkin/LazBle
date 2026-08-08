unit LazBleBackendTests;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  fpcunit,
  testregistry,
  LazBleTypes,
  LazBleBackend,
  FakeLazBleBackend;

type
  TRecordingEventSink = class(TInterfacedObject, ILazBleBackendEventSink)
  private
    FEvents: array of TLazBleBackendEvent;
    function GetEvent(const AIndex: Integer): TLazBleBackendEvent;
  public
    procedure HandleBackendEvent(const AEvent: TLazBleBackendEvent);
    function EventCount: Integer;
    property Events[const AIndex: Integer]: TLazBleBackendEvent read GetEvent;
  end;

  TLazBleBackendTest = class(TTestCase)
  private
    FBackend: ILazBleBackend;
    FBackendObject: TFakeLazBleBackend;
    FEventSink: ILazBleBackendEventSink;
    FEventSinkObject: TRecordingEventSink;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure SubmitStoresTypedCommandsAndReturnsDistinctIds;
    procedure SubmitDoesNotDeliverEventsSynchronously;
    procedure EmitPreservesEventIdentityAndPayload;
    procedure CancelOnlyRecordsTheRequestedOperation;
    procedure BeginShutdownReturnsAnIdWithoutSynchronousCompletion;
    procedure TerminalEventKindsAreExplicit;
  end;

implementation

function TRecordingEventSink.GetEvent(
  const AIndex: Integer): TLazBleBackendEvent;
begin
  Result := FEvents[AIndex];
end;

procedure TRecordingEventSink.HandleBackendEvent(
  const AEvent: TLazBleBackendEvent);
var
  Index: Integer;
begin
  Index := Length(FEvents);
  SetLength(FEvents, Index + 1);
  FEvents[Index] := AEvent;
end;

function TRecordingEventSink.EventCount: Integer;
begin
  Result := Length(FEvents);
end;

procedure TLazBleBackendTest.SetUp;
begin
  FBackendObject := TFakeLazBleBackend.Create;
  FBackend := FBackendObject;
  FEventSinkObject := TRecordingEventSink.Create;
  FEventSink := FEventSinkObject;
  FBackend.SetEventSink(FEventSink);
end;

procedure TLazBleBackendTest.TearDown;
begin
  FBackend.SetEventSink(nil);
  FEventSink := nil;
  FEventSinkObject := nil;
  FBackend := nil;
  FBackendObject := nil;
end;

procedure TLazBleBackendTest.SubmitStoresTypedCommandsAndReturnsDistinctIds;
var
  FirstCommand: TLazBleBackendCommand;
  SecondCommand: TLazBleBackendCommand;
  FirstId: TBleOperationId;
  SecondId: TBleOperationId;
begin
  FirstCommand := Default(TLazBleBackendCommand);
  FirstCommand.Kind := lbckConnect;
  FirstCommand.DeviceId := 'device-1';
  SecondCommand := Default(TLazBleBackendCommand);
  SecondCommand.Kind := lbckRead;
  SecondCommand.DeviceId := 'device-1';
  SecondCommand.ServiceUuid := '180f';
  SecondCommand.CharacteristicUuid := '2a19';

  FirstId := FBackend.Submit(FirstCommand);
  SecondId := FBackend.Submit(SecondCommand);

  AssertTrue('The first operation id must be valid',
    FirstId <> InvalidBleOperationId);
  AssertTrue('Operation ids must be distinct', FirstId <> SecondId);
  AssertEquals(2, FBackendObject.CommandCount);
  AssertEquals(Ord(lbckConnect), Ord(FBackendObject.Commands[0].Kind));
  AssertEquals('device-1', FBackendObject.Commands[0].DeviceId);
  AssertEquals(Ord(lbckRead), Ord(FBackendObject.Commands[1].Kind));
  AssertEquals('180f', FBackendObject.Commands[1].ServiceUuid);
  AssertTrue(FirstId = FBackendObject.OperationIds[0]);
  AssertTrue(SecondId = FBackendObject.OperationIds[1]);
end;

procedure TLazBleBackendTest.SubmitDoesNotDeliverEventsSynchronously;
var
  Command: TLazBleBackendCommand;
begin
  Command := Default(TLazBleBackendCommand);
  Command.Kind := lbckStartScan;

  FBackend.Submit(Command);

  AssertEquals(0, FEventSinkObject.EventCount);
end;

procedure TLazBleBackendTest.EmitPreservesEventIdentityAndPayload;
var
  BackendEvent: TLazBleBackendEvent;
begin
  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := lbekNotification;
  BackendEvent.OperationId := 7;
  BackendEvent.SubscriptionId := 11;
  BackendEvent.Generation := 3;
  BackendEvent.DeviceId := 'device-1';
  SetLength(BackendEvent.Value, 3);
  BackendEvent.Value[0] := $10;
  BackendEvent.Value[1] := $20;
  BackendEvent.Value[2] := $30;

  FBackendObject.Emit(BackendEvent);

  AssertEquals(1, FEventSinkObject.EventCount);
  AssertEquals(Ord(lbekNotification),
    Ord(FEventSinkObject.Events[0].Kind));
  AssertTrue(FEventSinkObject.Events[0].OperationId = 7);
  AssertTrue(FEventSinkObject.Events[0].SubscriptionId = 11);
  AssertTrue(FEventSinkObject.Events[0].Generation = 3);
  AssertEquals('device-1', FEventSinkObject.Events[0].DeviceId);
  AssertEquals(3, Length(FEventSinkObject.Events[0].Value));
  AssertEquals($20, Integer(FEventSinkObject.Events[0].Value[1]));
end;

procedure TLazBleBackendTest.CancelOnlyRecordsTheRequestedOperation;
begin
  FBackend.Cancel(42);

  AssertEquals(1, FBackendObject.CancelledOperationCount);
  AssertTrue(FBackendObject.CancelledOperationIds[0] = 42);
  AssertEquals(0, FEventSinkObject.EventCount);
end;

procedure TLazBleBackendTest.BeginShutdownReturnsAnIdWithoutSynchronousCompletion;
var
  ShutdownId: TBleOperationId;
begin
  ShutdownId := FBackend.BeginShutdown;

  AssertTrue(ShutdownId <> InvalidBleOperationId);
  AssertTrue(ShutdownId = FBackendObject.ShutdownOperationId);
  AssertEquals(0, FEventSinkObject.EventCount);
end;

procedure TLazBleBackendTest.TerminalEventKindsAreExplicit;
var
  BackendEvent: TLazBleBackendEvent;
begin
  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := lbekNotification;
  AssertFalse(LazBleBackendEventIsTerminal(BackendEvent));

  BackendEvent.Kind := lbekOperationSucceeded;
  AssertTrue(LazBleBackendEventIsTerminal(BackendEvent));
  BackendEvent.Kind := lbekOperationFailed;
  AssertTrue(LazBleBackendEventIsTerminal(BackendEvent));
  BackendEvent.Kind := lbekOperationCancelled;
  AssertTrue(LazBleBackendEventIsTerminal(BackendEvent));
  BackendEvent.Kind := lbekShutdownCompleted;
  AssertTrue(LazBleBackendEventIsTerminal(BackendEvent));
end;

initialization
  RegisterTest(TLazBleBackendTest);

end.
