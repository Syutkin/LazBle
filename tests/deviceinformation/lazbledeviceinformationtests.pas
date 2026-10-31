unit LazBleDeviceInformationTests;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, LazBleTypes, LazBleBackend,
  LazBleOperation, LazBleGattSession, LazBleGattProfile,
  LazBleDeviceInformation, FakeLazBleBackend, TestLazBleAccess;

type
  TTestDeviceInformationProfile = class(TBleDeviceInformationProfile)
  public
    procedure BindTo(const ASession: TBleGattSession);
    procedure AttachProfile;
    procedure DetachProfile;
  end;

  TDeviceInformationObserver = class
  public
    Count: Integer;
    DetachOnUpdate, RefreshOnUpdate: Boolean;
    NextRefresh: IBleOperation;
    procedure Updated(Sender: TObject);
    procedure StateChanged(Sender: TObject; const AState: TLazBleGattProfileState);
  end;

  TLazBleDeviceInformationTest = class(TTestCase)
  private
    FBackend: ILazBleBackend;
    FNative: TFakeLazBleBackend;
    FSession: TBleGattSession;
    FProfile: TTestDeviceInformationProfile;
    FObserver: TDeviceInformationObserver;
    FServices: TLazBleGattServices;
    procedure Add(const AUuid: string; const AReadable: Boolean = True);
    procedure Connect;
    procedure Attach;
    procedure CompleteRead(const AValue: array of Byte);
    procedure CompleteAt(const AId: TBleOperationId; const AValue: array of Byte);
    function LastId: TBleOperationId;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure EmptyServiceIsReadyWithoutReads;
    procedure ReadsOnlyAvailableStringsWithoutSubscriptions;
    procedure ReadsAllDeviceInformationCharacteristics;
    procedure EmptyStringIsPresent;
    procedure SystemIdRetainsAll64Bits;
    procedure PnpIdUsesLittleEndianAndBcdVersion;
    procedure FixedBinaryFieldsRejectTruncationAndTrailingBytes;
    procedure PnpIdRejectsReservedSourceAndInvalidBcd;
    procedure UdiDecodesOptionalStringsAndIgnoresReservedFlagBits;
    procedure UdiRejectsMalformedFields;
    procedure MalformedUtf8DoesNotReplaceSnapshot;
    procedure ReadFailurePreservesZeroNativeCode;
    procedure MissingServiceFails;
    procedure UnreadableCharacteristicFailsBeforeReading;
    procedure DuplicateServicesAreRejected;
    procedure DuplicateCharacteristicsAreRejected;
    procedure RefreshPublishesOneCompleteSnapshotAndRejectsBusy;
    procedure RefreshCancellationKeepsPreviousSnapshot;
    procedure DetachCancelsRefreshAndIgnoresLateRead;
    procedure ReconnectIgnoresOldRead;
    procedure DetachOnAttachingStartsNoRead;
    procedure UpdateHandlerCanStartNextRefresh;
    procedure DetachFromUpdateCompletesRefresh;
  end;

implementation

procedure TTestDeviceInformationProfile.BindTo(const ASession: TBleGattSession);
begin BindSession(ASession); end;
procedure TTestDeviceInformationProfile.AttachProfile;
begin Attach; end;
procedure TTestDeviceInformationProfile.DetachProfile;
begin Detach; end;

procedure TDeviceInformationObserver.Updated(Sender: TObject);
begin
  Inc(Count);
  if DetachOnUpdate then TTestDeviceInformationProfile(Sender).DetachProfile;
  if RefreshOnUpdate then
  begin
    RefreshOnUpdate := False;
    NextRefresh := TTestDeviceInformationProfile(Sender).RefreshAsync;
  end;
end;

procedure TDeviceInformationObserver.StateChanged(Sender: TObject;
  const AState: TLazBleGattProfileState);
begin
  if AState = lbgpsAttaching then TTestDeviceInformationProfile(Sender).DetachProfile;
end;

procedure TLazBleDeviceInformationTest.SetUp;
begin
  FNative := TFakeLazBleBackend.Create;
  FBackend := FNative;
  FSession := LazBleTestCreateSession('device-1', @FNative.Submit, @FNative.Cancel);
  FProfile := TTestDeviceInformationProfile.Create;
  FProfile.BindTo(FSession);
  FObserver := TDeviceInformationObserver.Create;
  FProfile.OnUpdated := @FObserver.Updated;
  SetLength(FServices, 1);
  FServices[0].Uuid := DeviceInformationServiceUuid;
end;

procedure TLazBleDeviceInformationTest.TearDown;
begin
  FProfile.Free;
  FObserver.Free;
  FSession.Free;
  FBackend := nil;
end;

procedure TLazBleDeviceInformationTest.Add(const AUuid: string;
  const AReadable: Boolean);
var I: Integer;
begin
  I := Length(FServices[0].Characteristics);
  SetLength(FServices[0].Characteristics, I + 1);
  FServices[0].Characteristics[I].Uuid := UTF8Decode(AUuid);
  FServices[0].Characteristics[I].CanRead := AReadable;
end;

function TLazBleDeviceInformationTest.LastId: TBleOperationId;
begin Result := FNative.OperationIds[FNative.CommandCount - 1]; end;

procedure TLazBleDeviceInformationTest.Connect;
var Id: TBleOperationId; Event: TLazBleBackendEvent; R: TLazBleRequestResult;
begin
  Id := LazBleTestConnect(FSession);
  Event := Default(TLazBleBackendEvent);
  Event.Kind := lbekConnected; Event.DeviceId := FSession.DeviceId;
  Event.Generation := FSession.Generation; Event.OperationId := Id;
  AssertTrue(FNative.EmitProgress(Event));
  AssertTrue(FNative.CompleteOperation(Id, lbekOperationSucceeded));
  R := Default(TLazBleRequestResult);
  R.Status := lbrsSucceeded; R.Services := FServices;
  AssertTrue(FNative.FinishRequest(LastId, R));
end;

procedure TLazBleDeviceInformationTest.Attach;
begin Connect; FProfile.AttachProfile; end;

procedure TLazBleDeviceInformationTest.CompleteAt(const AId: TBleOperationId;
  const AValue: array of Byte);
var R: TLazBleRequestResult; I: Integer;
begin
  R := Default(TLazBleRequestResult); R.Status := lbrsSucceeded;
  SetLength(R.Value, Length(AValue));
  for I := 0 to High(AValue) do R.Value[I] := AValue[I];
  AssertTrue(FNative.FinishRequest(AId, R));
end;

procedure TLazBleDeviceInformationTest.CompleteRead(const AValue: array of Byte);
begin
  AssertEquals(Ord(lbckRead), Ord(FNative.Commands[FNative.CommandCount - 1].Kind));
  CompleteAt(LastId, AValue);
end;

procedure TLazBleDeviceInformationTest.EmptyServiceIsReadyWithoutReads;
begin
  Attach;
  AssertTrue(FProfile.Ready);
  AssertTrue(FProfile.Data.PresentFields = []);
  AssertTrue(FProfile.AvailableCharacteristics = []);
  AssertEquals(2, FNative.CommandCount);
  AssertEquals(1, FObserver.Count);
end;

procedure TLazBleDeviceInformationTest.ReadsOnlyAvailableStringsWithoutSubscriptions;
begin
  Add(DeviceInformationFirmwareRevisionUuid);
  Add(DeviceInformationManufacturerNameUuid);
  Attach;
  AssertFalse(FProfile.Ready);
  AssertEquals(DeviceInformationManufacturerNameUuid, FNative.Commands[2].CharacteristicUuid);
  CompleteRead([$D0, $A2]);
  AssertTrue(FProfile.Data.PresentFields = []);
  CompleteRead([$31, $2E, $30]);
  AssertTrue(FProfile.Ready);
  AssertEquals(UTF8String(#$D0#$A2), FProfile.Data.ManufacturerName);
  AssertEquals('1.0', FProfile.Data.FirmwareRevision);
  AssertTrue(FProfile.Data.PresentFields = [dicManufacturerName, dicFirmwareRevision]);
  AssertEquals(4, FNative.CommandCount);
  AssertEquals(1, FObserver.Count);
end;

procedure TLazBleDeviceInformationTest.ReadsAllDeviceInformationCharacteristics;
begin
  Add(DeviceInformationManufacturerNameUuid); Add(DeviceInformationModelNumberUuid);
  Add(DeviceInformationSerialNumberUuid); Add(DeviceInformationHardwareRevisionUuid);
  Add(DeviceInformationFirmwareRevisionUuid); Add(DeviceInformationSoftwareRevisionUuid);
  Add(DeviceInformationSystemIdUuid); Add(DeviceInformationRegulatoryCertificationDataListUuid);
  Add(DeviceInformationPnpIdUuid); Add(DeviceInformationUdiForMedicalDevicesUuid);
  Attach;
  CompleteRead([$4D]); CompleteRead([$31]); CompleteRead([$32]);
  CompleteRead([$33]); CompleteRead([$34]); CompleteRead([$35]);
  CompleteRead([1, 2, 3, 4, 5, 6, 7, 8]);
  CompleteRead([$AA, $BB]);
  CompleteRead([1, $34, $12, $78, $56, $13, $02]);
  CompleteRead([$0F, $4C, 0, $44, 0, $49, 0, $41, 0]);
  AssertTrue(FProfile.Ready);
  AssertTrue(FProfile.Data.PresentFields = [Low(TBleDeviceInformationCharacteristic)..High(TBleDeviceInformationCharacteristic)]);
  AssertEquals('M', FProfile.Data.ManufacturerName);
  AssertEquals('1', FProfile.Data.ModelNumber);
  AssertEquals('2', FProfile.Data.SerialNumber);
  AssertEquals('3', FProfile.Data.HardwareRevision);
  AssertEquals('4', FProfile.Data.FirmwareRevision);
  AssertEquals('5', FProfile.Data.SoftwareRevision);
  AssertEquals($AA, Integer(FProfile.Data.RegulatoryCertificationDataList[0]));
  AssertEquals('L', FProfile.Data.UdiForMedicalDevices.UdiLabel);
  AssertEquals('D', FProfile.Data.UdiForMedicalDevices.UdiDeviceIdentifier);
  AssertEquals('I', FProfile.Data.UdiForMedicalDevices.UdiIssuer);
  AssertEquals('A', FProfile.Data.UdiForMedicalDevices.UdiAuthority);
  AssertEquals(1, FObserver.Count);
  AssertEquals(12, FNative.CommandCount);
end;

procedure TLazBleDeviceInformationTest.EmptyStringIsPresent;
begin
  Add(DeviceInformationModelNumberUuid); Attach; CompleteRead([]);
  AssertTrue(FProfile.Ready);
  AssertTrue(dicModelNumber in FProfile.Data.PresentFields);
  AssertFalse(dicManufacturerName in FProfile.Data.PresentFields);
  AssertEquals('', FProfile.Data.ModelNumber);
end;

procedure TLazBleDeviceInformationTest.SystemIdRetainsAll64Bits;
begin
  Add(DeviceInformationSystemIdUuid); Attach;
  CompleteRead([$FF, $EE, $DD, $CC, $BB, $AA, $99, $88]);
  AssertTrue(FProfile.Ready);
  AssertEquals(QWord($BBCCDDEEFF), FProfile.Data.SystemId.ManufacturerIdentifier);
  AssertEquals(Cardinal($8899AA), FProfile.Data.SystemId.OrganizationallyUniqueIdentifier);
end;

procedure TLazBleDeviceInformationTest.PnpIdUsesLittleEndianAndBcdVersion;
begin
  Add(DeviceInformationPnpIdUuid); Attach;
  CompleteRead([2, $34, $12, $78, $56, $13, $02]);
  AssertTrue(FProfile.Ready);
  AssertEquals(2, FProfile.Data.PnpId.VendorIdSource);
  AssertEquals($1234, FProfile.Data.PnpId.VendorId);
  AssertEquals($5678, FProfile.Data.PnpId.ProductId);
  AssertEquals($0213, FProfile.Data.PnpId.ProductVersion);
end;

procedure TLazBleDeviceInformationTest.FixedBinaryFieldsRejectTruncationAndTrailingBytes;
var Kind, N, Size: Integer; Bytes: TBytes;
begin
  for Kind := 0 to 1 do
  begin
    if Kind = 0 then Size := 8 else Size := 7;
    SetLength(FServices[0].Characteristics, 0);
    if Kind = 0 then Add(DeviceInformationSystemIdUuid) else Add(DeviceInformationPnpIdUuid);
    Connect;
    for N := 0 to Size + 1 do
    begin
      if N = Size then Continue;
      SetLength(Bytes, N);
      FProfile.AttachProfile;
      CompleteRead(Bytes);
      AssertEquals(Ord(lbgpsError), Ord(FProfile.State));
      AssertEquals(LazBleErrorInvalidProfileData, FProfile.ErrorCode);
      FProfile.DetachProfile;
    end;
    if Kind = 0 then
    begin
      N := LazBleTestDisconnect(FSession);
      AssertTrue(FNative.CompleteOperation(N, lbekOperationSucceeded));
    end;
  end;
end;

procedure TLazBleDeviceInformationTest.PnpIdRejectsReservedSourceAndInvalidBcd;
begin
  Add(DeviceInformationPnpIdUuid); Attach;
  CompleteRead([0, 0, 0, 0, 0, 0, 0]);
  AssertEquals(LazBleErrorInvalidProfileData, FProfile.ErrorCode);
  FProfile.DetachProfile; FProfile.AttachProfile;
  CompleteRead([1, 0, 0, 0, 0, $FA, 0]);
  AssertEquals(LazBleErrorInvalidProfileData, FProfile.ErrorCode);
end;

procedure TLazBleDeviceInformationTest.UdiDecodesOptionalStringsAndIgnoresReservedFlagBits;
begin
  Add(DeviceInformationUdiForMedicalDevicesUuid); Attach;
  CompleteRead([$F2, $44, 0]);
  AssertTrue(FProfile.Ready);
  AssertFalse(FProfile.Data.UdiForMedicalDevices.HasUdiLabel);
  AssertTrue(FProfile.Data.UdiForMedicalDevices.HasUdiDeviceIdentifier);
  AssertFalse(FProfile.Data.UdiForMedicalDevices.HasUdiIssuer);
  AssertEquals('D', FProfile.Data.UdiForMedicalDevices.UdiDeviceIdentifier);
end;

procedure TLazBleDeviceInformationTest.UdiRejectsMalformedFields;
begin
  Add(DeviceInformationUdiForMedicalDevicesUuid); Attach;
  CompleteRead([1, $4C]); { missing zero terminator }
  AssertEquals(LazBleErrorInvalidProfileData, FProfile.ErrorCode);
  FProfile.DetachProfile; FProfile.AttachProfile;
  CompleteRead([1, $C0, $80, 0]);
  AssertEquals(LazBleErrorInvalidProfileData, FProfile.ErrorCode);
  FProfile.DetachProfile; FProfile.AttachProfile;
  CompleteRead([4, $49, 0]); { no label or device identifier }
  AssertEquals(LazBleErrorInvalidProfileData, FProfile.ErrorCode);
  FProfile.DetachProfile; FProfile.AttachProfile;
  CompleteRead([1, $4C, 0, $FF]);
  AssertEquals(LazBleErrorInvalidProfileData, FProfile.ErrorCode);
end;

procedure TLazBleDeviceInformationTest.MalformedUtf8DoesNotReplaceSnapshot;
var Refresh: IBleOperation;
begin
  Add(DeviceInformationManufacturerNameUuid); Attach; CompleteRead([$4D]);
  Refresh := FProfile.RefreshAsync;
  CompleteRead([$C0, $80]);
  AssertEquals(Ord(lbopFailed), Ord(Refresh.State));
  AssertEquals(LazBleErrorInvalidProfileData, Refresh.ErrorCode);
  AssertEquals('M', FProfile.Data.ManufacturerName);
  AssertEquals(1, FObserver.Count);
end;

procedure TLazBleDeviceInformationTest.ReadFailurePreservesZeroNativeCode;
begin
  Add(DeviceInformationManufacturerNameUuid); Attach;
  AssertTrue(FNative.CompleteOperation(LastId, lbekOperationFailed, 0, ''));
  AssertEquals(Ord(lbgpsError), Ord(FProfile.State));
  AssertEquals(0, FProfile.ErrorCode);
  AssertTrue(FProfile.Data.PresentFields = []);
end;

procedure TLazBleDeviceInformationTest.MissingServiceFails;
begin
  FServices := nil; Attach;
  AssertEquals(LazBleErrorGattNotFound, FProfile.ErrorCode);
  AssertEquals(Ord(lbgpsError), Ord(FProfile.State));
  AssertEquals(2, FNative.CommandCount);
end;

procedure TLazBleDeviceInformationTest.UnreadableCharacteristicFailsBeforeReading;
begin
  Add(DeviceInformationManufacturerNameUuid);
  Add(DeviceInformationFirmwareRevisionUuid, False); Attach;
  AssertEquals(LazBleErrorGattPropertyNotSupported, FProfile.ErrorCode);
  AssertEquals(2, FNative.CommandCount);
end;

procedure TLazBleDeviceInformationTest.DuplicateServicesAreRejected;
begin
  SetLength(FServices, 2); FServices[1].Uuid := DeviceInformationServiceUuid;
  Attach;
  AssertEquals(LazBleErrorInvalidProfileData, FProfile.ErrorCode);
  AssertEquals(2, FNative.CommandCount);
end;

procedure TLazBleDeviceInformationTest.DuplicateCharacteristicsAreRejected;
begin
  Add(DeviceInformationManufacturerNameUuid); Add(DeviceInformationManufacturerNameUuid);
  Attach;
  AssertEquals(LazBleErrorInvalidProfileData, FProfile.ErrorCode);
  AssertEquals(2, FNative.CommandCount);
end;

procedure TLazBleDeviceInformationTest.RefreshPublishesOneCompleteSnapshotAndRejectsBusy;
var Refresh, Busy: IBleOperation; Old: TBleDeviceInformationData;
begin
  Add(DeviceInformationManufacturerNameUuid); Add(DeviceInformationModelNumberUuid);
  Attach; CompleteRead([$41]); CompleteRead([$31]); Old := FProfile.Data;
  Refresh := FProfile.RefreshAsync;
  Busy := FProfile.RefreshAsync;
  AssertEquals(Ord(lbopFailed), Ord(Busy.State));
  AssertTrue(FProfile.Ready);
  CompleteRead([$42]);
  AssertEquals('A', FProfile.Data.ManufacturerName);
  AssertEquals(Ord(lbopPending), Ord(Refresh.State));
  CompleteRead([$32]);
  AssertEquals(Ord(lbopSucceeded), Ord(Refresh.State));
  AssertEquals('B', FProfile.Data.ManufacturerName);
  AssertEquals('2', FProfile.Data.ModelNumber);
  AssertEquals('A', Old.ManufacturerName);
  AssertEquals(2, FObserver.Count);
end;

procedure TLazBleDeviceInformationTest.RefreshCancellationKeepsPreviousSnapshot;
var Refresh: IBleOperation; Count: Integer;
begin
  Add(DeviceInformationManufacturerNameUuid); Add(DeviceInformationModelNumberUuid);
  Attach; CompleteRead([$41]); CompleteRead([$31]);
  Refresh := FProfile.RefreshAsync; Count := FNative.CommandCount;
  Refresh.Cancel;
  AssertTrue(FNative.CancellationWasRequested(LastId));
  CompleteRead([$42]);
  AssertEquals(Ord(lbopCancelled), Ord(Refresh.State));
  AssertTrue(FProfile.Ready);
  AssertEquals('A', FProfile.Data.ManufacturerName);
  AssertEquals(Count, FNative.CommandCount);
end;

procedure TLazBleDeviceInformationTest.DetachCancelsRefreshAndIgnoresLateRead;
var Refresh: IBleOperation; Id: TBleOperationId;
begin
  Add(DeviceInformationManufacturerNameUuid); Attach; CompleteRead([$41]);
  Refresh := FProfile.RefreshAsync; Id := LastId;
  FProfile.DetachProfile;
  AssertEquals(Ord(lbopCancelled), Ord(Refresh.State));
  AssertTrue(FProfile.Data.PresentFields = []);
  AssertTrue(FProfile.AvailableCharacteristics = []);
  CompleteAt(Id, [$42]);
  AssertTrue(FProfile.Data.PresentFields = []);
  AssertEquals(1, FObserver.Count);
end;

procedure TLazBleDeviceInformationTest.ReconnectIgnoresOldRead;
var Id, DisconnectId: TBleOperationId;
begin
  Add(DeviceInformationManufacturerNameUuid); Attach; Id := LastId;
  FProfile.DetachProfile;
  DisconnectId := LazBleTestDisconnect(FSession);
  AssertTrue(FNative.CompleteOperation(DisconnectId, lbekOperationSucceeded));
  Connect; FProfile.AttachProfile;
  CompleteAt(Id, [$41]);
  AssertFalse(FProfile.Ready);
  AssertTrue(FProfile.Data.PresentFields = []);
  CompleteRead([$42]);
  AssertTrue(FProfile.Ready);
  AssertEquals('B', FProfile.Data.ManufacturerName);
end;

procedure TLazBleDeviceInformationTest.DetachOnAttachingStartsNoRead;
begin
  Add(DeviceInformationManufacturerNameUuid);
  FProfile.OnStateChanged := @FObserver.StateChanged;
  Attach;
  AssertEquals(Ord(lbgpsDetached), Ord(FProfile.State));
  AssertEquals(2, FNative.CommandCount);
end;

procedure TLazBleDeviceInformationTest.UpdateHandlerCanStartNextRefresh;
var Refresh: IBleOperation;
begin
  Add(DeviceInformationManufacturerNameUuid); Attach; CompleteRead([$41]);
  FObserver.RefreshOnUpdate := True;
  Refresh := FProfile.RefreshAsync; CompleteRead([$42]);
  AssertEquals(Ord(lbopSucceeded), Ord(Refresh.State));
  AssertEquals(Ord(lbopPending), Ord(FObserver.NextRefresh.State));
  CompleteRead([$43]);
  AssertEquals(Ord(lbopSucceeded), Ord(FObserver.NextRefresh.State));
  AssertEquals('C', FProfile.Data.ManufacturerName);
end;

procedure TLazBleDeviceInformationTest.DetachFromUpdateCompletesRefresh;
var Refresh: IBleOperation;
begin
  Add(DeviceInformationManufacturerNameUuid); Attach; CompleteRead([$41]);
  FObserver.DetachOnUpdate := True;
  Refresh := FProfile.RefreshAsync; CompleteRead([$42]);
  AssertEquals(Ord(lbopSucceeded), Ord(Refresh.State));
  AssertEquals(Ord(lbgpsDetached), Ord(FProfile.State));
  AssertTrue(FProfile.Data.PresentFields = []);
end;

initialization
  RegisterTest(TLazBleDeviceInformationTest);
end.
