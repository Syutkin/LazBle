unit LazBleGattProfileTests;

{$mode objfpc}{$H+}

interface

uses
  fpcunit,
  testregistry,
  LazBleGattSession,
  LazBleGattProfile;

type
  TTestGattProfile = class(TBleGattProfile)
  private
    FAttachCount: Integer;
    FDetachCount: Integer;
  protected
    procedure DoAttach; override;
    procedure DoDetach; override;
  public
    procedure CompleteAttach;
    procedure FailAttach(const AMessage: string);
    property AttachCount: Integer read FAttachCount;
    property DetachCount: Integer read FDetachCount;
  end;

  TLazBleGattProfileTest = class(TTestCase)
  private
    FSession: TBleGattSession;
    FProfile: TTestGattProfile;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure AttachCapturesGenerationAndBecomesReady;
    procedure AttachAndDetachAreIdempotent;
    procedure DetachClearsErrorAndAllowsReattach;
  end;

implementation

procedure TTestGattProfile.DoAttach;
begin
  Inc(FAttachCount);
end;

procedure TTestGattProfile.DoDetach;
begin
  Inc(FDetachCount);
end;

procedure TTestGattProfile.CompleteAttach;
begin
  MarkReady;
end;

procedure TTestGattProfile.FailAttach(const AMessage: string);
begin
  MarkError(AMessage);
end;

procedure TLazBleGattProfileTest.SetUp;
begin
  FSession := TBleGattSession.Create('device-1', nil, nil);
  FSession.Connect;
  FProfile := TTestGattProfile.Create(FSession);
end;

procedure TLazBleGattProfileTest.TearDown;
begin
  FProfile.Free;
  FProfile := nil;
  FSession.Free;
  FSession := nil;
end;

procedure TLazBleGattProfileTest.AttachCapturesGenerationAndBecomesReady;
begin
  FProfile.Attach;

  AssertEquals(1, FProfile.AttachCount);
  AssertTrue(FProfile.AttachedGeneration = FSession.Generation);
  AssertEquals(Ord(lbgpsAttaching), Ord(FProfile.State));

  FProfile.CompleteAttach;
  AssertTrue(FProfile.Ready);
  AssertEquals(Ord(lbgpsReady), Ord(FProfile.State));
end;

procedure TLazBleGattProfileTest.AttachAndDetachAreIdempotent;
begin
  FProfile.Attach;
  FProfile.Attach;
  FProfile.CompleteAttach;
  FProfile.Detach;
  FProfile.Detach;

  AssertEquals(1, FProfile.AttachCount);
  AssertEquals(1, FProfile.DetachCount);
  AssertEquals(Ord(lbgpsDetached), Ord(FProfile.State));
  AssertTrue(FProfile.AttachedGeneration = 0);
end;

procedure TLazBleGattProfileTest.DetachClearsErrorAndAllowsReattach;
begin
  FProfile.Attach;
  FProfile.FailAttach('attach failed');
  AssertEquals(Ord(lbgpsError), Ord(FProfile.State));
  AssertEquals('attach failed', FProfile.ErrorMessage);

  FProfile.Detach;
  AssertEquals('', FProfile.ErrorMessage);
  FProfile.Attach;

  AssertEquals(2, FProfile.AttachCount);
  AssertEquals(Ord(lbgpsAttaching), Ord(FProfile.State));
end;

initialization
  RegisterTest(TLazBleGattProfileTest);

end.
