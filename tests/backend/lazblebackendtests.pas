unit LazBleBackendTests;

{$mode objfpc}{$H+}

interface

uses SysUtils, fpcunit, testregistry, LazBleTypes, LazBleBackend, FakeLazBleBackend;

type
  TRequestRecorder = class(TInterfacedObject, ILazBleRequestCompletion)
  public
    Count: Integer;
    Last: TLazBleRequestResult;
    procedure CompleteRequest(const AResult: TLazBleRequestResult);
  end;

  TLazBleBackendTest = class(TTestCase)
  private
    FBackend: ILazBleBackend;
    FFake: TFakeLazBleBackend;
    FTarget: ILazBleRequestCompletion;
    FRecorder: TRequestRecorder;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure SubmitStoresTypedCommandsAndReturnsDistinctIds;
    procedure SubmitDoesNotCompleteSynchronously;
    procedure CompletePreservesStatusAndPayload;
    procedure CancelOnlyRecordsTheRequestedOperation;
    procedure BeginShutdownReturnsAnIdWithoutSynchronousCompletion;
    procedure FailureStatusIsIndependentOfCodeAndText;
    procedure SubmitWithoutRecipientIsRejected;
  end;

implementation

procedure TRequestRecorder.CompleteRequest(const AResult: TLazBleRequestResult);
begin LazBleRequireMainThread; Last := AResult; Inc(Count); end;

procedure TLazBleBackendTest.SetUp;
begin
  FFake := TFakeLazBleBackend.Create; FBackend := FFake;
  FRecorder := TRequestRecorder.Create; FTarget := FRecorder;
end;

procedure TLazBleBackendTest.TearDown;
begin FBackend := nil; FTarget := nil; end;

procedure TLazBleBackendTest.SubmitStoresTypedCommandsAndReturnsDistinctIds;
var C: TLazBleBackendCommand; First, Second: TBleOperationId;
begin
  C := Default(TLazBleBackendCommand); C.Kind := lbckWrite;
  C.DeviceId := 'device'; C.ServiceUuid := 'service'; C.CharacteristicUuid := 'value';
  C.Value := TBytes.Create(42);
  First := FBackend.Submit(C, FTarget); Second := FBackend.Submit(C, FTarget);
  C.Value[0] := 99;
  AssertTrue(First <> InvalidBleOperationId); AssertTrue(First <> Second);
  AssertEquals(2, FFake.CommandCount);
  AssertEquals('device', FFake.Commands[0].DeviceId);
  AssertEquals('service', FFake.Commands[0].ServiceUuid);
  AssertEquals('value', FFake.Commands[0].CharacteristicUuid);
  AssertEquals(42, FFake.Commands[0].Value[0]);
end;

procedure TLazBleBackendTest.SubmitDoesNotCompleteSynchronously;
begin
  FBackend.Submit(Default(TLazBleBackendCommand), FTarget);
  AssertEquals(0, FRecorder.Count);
end;

procedure TLazBleBackendTest.CompletePreservesStatusAndPayload;
var Id: TBleOperationId; R: TLazBleRequestResult;
begin
  Id := FBackend.Submit(Default(TLazBleBackendCommand), FTarget);
  R := Default(TLazBleRequestResult); R.Status := lbrsSucceeded;
  R.Value := TBytes.Create(42); R.AdapterId := 'adapter';
  AssertTrue(FFake.FinishRequest(Id, R));
  AssertEquals(1, FRecorder.Count);
  AssertEquals(42, FRecorder.Last.Value[0]); AssertEquals('adapter', FRecorder.Last.AdapterId);
end;

procedure TLazBleBackendTest.CancelOnlyRecordsTheRequestedOperation;
var First, Second: TBleOperationId;
begin
  First := FBackend.Submit(Default(TLazBleBackendCommand), FTarget);
  Second := FBackend.Submit(Default(TLazBleBackendCommand), FTarget);
  FBackend.Cancel(Second); FBackend.Cancel(Second);
  AssertFalse(FFake.CancellationWasRequested(First));
  AssertTrue(FFake.CancellationWasRequested(Second));
  AssertEquals(1, FFake.CancelledOperationCount); AssertEquals(0, FRecorder.Count);
end;

procedure TLazBleBackendTest.BeginShutdownReturnsAnIdWithoutSynchronousCompletion;
begin
  AssertTrue(FBackend.BeginShutdown(FTarget) <> InvalidBleOperationId);
  AssertEquals(0, FRecorder.Count);
  AssertTrue(FFake.CompleteShutdown); AssertEquals(1, FRecorder.Count);
end;

procedure TLazBleBackendTest.FailureStatusIsIndependentOfCodeAndText;
var Id: TBleOperationId; R: TLazBleRequestResult;
begin
  Id := FBackend.Submit(Default(TLazBleBackendCommand), FTarget);
  R := Default(TLazBleRequestResult); R.Status := lbrsFailed;
  AssertTrue(FFake.FinishRequest(Id, R));
  AssertEquals(Ord(lbrsFailed), Ord(FRecorder.Last.Status));
  AssertEquals(0, FRecorder.Last.ErrorCode); AssertEquals('', FRecorder.Last.ErrorMessage);
end;

procedure TLazBleBackendTest.SubmitWithoutRecipientIsRejected;
begin
  AssertTrue(FBackend.Submit(Default(TLazBleBackendCommand), nil) = InvalidBleOperationId);
  AssertEquals(0, FFake.CommandCount);
end;

initialization
  RegisterTest(TLazBleBackendTest);
end.
