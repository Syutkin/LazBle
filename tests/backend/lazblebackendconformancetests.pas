unit LazBleBackendConformanceTests;

{$mode objfpc}{$H+}

interface

uses SysUtils, fpcunit, testregistry, LazBleTypes, LazBleBackend,
  FakeLazBleBackend, LazBleBackendTests;

type
  TFakeLazBleBackendConformanceTest = class(TTestCase)
  private
    FBackend: ILazBleBackend;
    FFake: TFakeLazBleBackend;
    FFirst, FSecond, FShutdown: TRequestRecorder;
    FFirstRef, FSecondRef, FShutdownRef: ILazBleRequestCompletion;
    function Submit(const Target: ILazBleRequestCompletion; Generation: QWord = 1): TBleOperationId;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure CompletesExactlyOnce;
    procedure CancelCompletesAsynchronously;
    procedure StartedCancellationRetainsActualValue;
    procedure ShutdownDrainsEveryRecipientBeforeCompleting;
    procedure OldRequestKeepsItsRecipientAcrossGenerations;
    procedure RejectsLateResultsAfterCompletion;
    procedure EmitsNothingAfterTerminalShutdown;
  end;

implementation

procedure TFakeLazBleBackendConformanceTest.SetUp;
begin
  FFake := TFakeLazBleBackend.Create; FBackend := FFake;
  FFirst := TRequestRecorder.Create; FFirstRef := FFirst;
  FSecond := TRequestRecorder.Create; FSecondRef := FSecond;
  FShutdown := TRequestRecorder.Create; FShutdownRef := FShutdown;
end;

procedure TFakeLazBleBackendConformanceTest.TearDown;
begin
  FBackend := nil; FFirstRef := nil; FSecondRef := nil; FShutdownRef := nil;
end;

function TFakeLazBleBackendConformanceTest.Submit(const Target: ILazBleRequestCompletion;
  Generation: QWord): TBleOperationId;
var C: TLazBleBackendCommand;
begin
  C := Default(TLazBleBackendCommand); C.Kind := lbckRead;
  C.DeviceId := 'device'; C.Generation := Generation;
  Result := FBackend.Submit(C, Target);
end;

procedure TFakeLazBleBackendConformanceTest.CompletesExactlyOnce;
var Id: TBleOperationId; R: TLazBleRequestResult;
begin
  Id := Submit(FFirstRef); R := Default(TLazBleRequestResult); R.Status := lbrsSucceeded;
  AssertTrue(FFake.FinishRequest(Id, R));
  R.Status := lbrsFailed; AssertFalse(FFake.FinishRequest(Id, R));
  R.Status := lbrsCancelled; AssertFalse(FFake.FinishRequest(Id, R));
  AssertEquals(1, FFirst.Count); AssertEquals(Ord(lbrsSucceeded), Ord(FFirst.Last.Status));
end;

procedure TFakeLazBleBackendConformanceTest.CancelCompletesAsynchronously;
var Id: TBleOperationId; R: TLazBleRequestResult;
begin
  Id := Submit(FFirstRef); FBackend.Cancel(Id);
  AssertEquals(0, FFirst.Count); AssertTrue(FFake.CancellationWasRequested(Id));
  R := Default(TLazBleRequestResult); R.Status := lbrsCancelled;
  AssertTrue(FFake.FinishRequest(Id, R));
  AssertEquals(1, FFirst.Count); AssertEquals(Ord(lbrsCancelled), Ord(FFirst.Last.Status));
end;

procedure TFakeLazBleBackendConformanceTest.StartedCancellationRetainsActualValue;
var Id: TBleOperationId; R: TLazBleRequestResult;
begin
  Id := Submit(FFirstRef); FBackend.Cancel(Id);
  R := Default(TLazBleRequestResult); R.Status := lbrsSucceeded; R.Value := TBytes.Create(42);
  AssertTrue(FFake.FinishRequest(Id, R));
  AssertEquals(Ord(lbrsSucceeded), Ord(FFirst.Last.Status)); AssertEquals(42, FFirst.Last.Value[0]);
end;

procedure TFakeLazBleBackendConformanceTest.ShutdownDrainsEveryRecipientBeforeCompleting;
var First, Second, ShutdownId: TBleOperationId; R: TLazBleRequestResult;
begin
  First := Submit(FFirstRef); Second := Submit(FSecondRef);
  ShutdownId := FBackend.BeginShutdown(FShutdownRef);
  AssertTrue(ShutdownId <> InvalidBleOperationId);
  AssertTrue(ShutdownId = FBackend.BeginShutdown);
  AssertTrue(FFake.CancellationWasRequested(First)); AssertTrue(FFake.CancellationWasRequested(Second));
  AssertTrue(Submit(FFirstRef) = InvalidBleOperationId);
  AssertFalse(FFake.CompleteShutdown); AssertEquals(0, FShutdown.Count);
  R := Default(TLazBleRequestResult); R.Status := lbrsCancelled;
  AssertTrue(FFake.FinishRequest(First, R)); AssertEquals(0, FShutdown.Count);
  AssertTrue(FFake.FinishRequest(Second, R)); AssertTrue(FFake.CompleteShutdown);
  AssertEquals(1, FFirst.Count); AssertEquals(1, FSecond.Count); AssertEquals(1, FShutdown.Count);
end;

procedure TFakeLazBleBackendConformanceTest.OldRequestKeepsItsRecipientAcrossGenerations;
var First, Second: TBleOperationId; R: TLazBleRequestResult;
begin
  First := Submit(FFirstRef, 1); Second := Submit(FSecondRef, 2);
  R := Default(TLazBleRequestResult); R.Status := lbrsSucceeded; R.Value := TBytes.Create(22);
  AssertTrue(FFake.FinishRequest(Second, R)); AssertEquals(0, FFirst.Count);
  R.Value := TBytes.Create(11); AssertTrue(FFake.FinishRequest(First, R));
  AssertEquals(11, FFirst.Last.Value[0]); AssertEquals(22, FSecond.Last.Value[0]);
end;

procedure TFakeLazBleBackendConformanceTest.RejectsLateResultsAfterCompletion;
var Id: TBleOperationId; E: TLazBleBackendEvent;
begin
  Id := Submit(FFirstRef); AssertTrue(FFake.CompleteOperation(Id, lbekOperationSucceeded));
  E := Default(TLazBleBackendEvent); E.Kind := lbekReadResult; E.OperationId := Id;
  AssertFalse(FFake.EmitProgress(E)); AssertEquals(1, FFirst.Count);
end;

procedure TFakeLazBleBackendConformanceTest.EmitsNothingAfterTerminalShutdown;
var Id: TBleOperationId; E: TLazBleBackendEvent;
begin
  Id := FBackend.BeginShutdown(FShutdownRef); AssertTrue(FFake.CompleteShutdown);
  E := Default(TLazBleBackendEvent); E.Kind := lbekScanResult; E.OperationId := 99;
  AssertFalse(FFake.EmitProgress(E)); AssertFalse(FFake.CompleteOperation(99, lbekOperationSucceeded));
  AssertTrue(Id = FBackend.BeginShutdown); AssertEquals(1, FShutdown.Count);
end;

initialization
  RegisterTest(TFakeLazBleBackendConformanceTest);
end.
