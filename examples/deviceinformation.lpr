program DeviceInformation;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, LazBleTypes, LazBleClient, LazBleSync,
  LazBleDeviceInformation;

procedure PrintInformation(const Data: TBleDeviceInformationData);

  procedure PrintText(const Field: TBleDeviceInformationCharacteristic;
    const Name: string; const Value: UTF8String);
  begin
    if Field in Data.PresentFields then WriteLn(Name, ': ', Value);
  end;

var I: Integer;
begin
  PrintText(dicManufacturerName, 'Manufacturer Name', Data.ManufacturerName);
  PrintText(dicModelNumber, 'Model Number', Data.ModelNumber);
  PrintText(dicSerialNumber, 'Serial Number', Data.SerialNumber);
  PrintText(dicHardwareRevision, 'Hardware Revision', Data.HardwareRevision);
  PrintText(dicFirmwareRevision, 'Firmware Revision', Data.FirmwareRevision);
  PrintText(dicSoftwareRevision, 'Software Revision', Data.SoftwareRevision);
  if dicSystemId in Data.PresentFields then
    WriteLn('System ID: OUI=', IntToHex(Data.SystemId.OrganizationallyUniqueIdentifier, 6),
      ' manufacturer identifier=', IntToHex(Data.SystemId.ManufacturerIdentifier, 10));
  if dicPnpId in Data.PresentFields then
    WriteLn('PnP ID: source=', Data.PnpId.VendorIdSource,
      ' vendor=', IntToHex(Data.PnpId.VendorId, 4),
      ' product=', IntToHex(Data.PnpId.ProductId, 4),
      ' version (BCD)=', IntToHex(Data.PnpId.ProductVersion, 4));
  if dicRegulatoryCertificationDataList in Data.PresentFields then
  begin
    Write('IEEE 11073-20601 Regulatory Certification Data List:');
    for I := 0 to High(Data.RegulatoryCertificationDataList) do
      Write(' ', IntToHex(Data.RegulatoryCertificationDataList[I], 2));
    WriteLn;
  end;
  if dicUdiForMedicalDevices in Data.PresentFields then
    with Data.UdiForMedicalDevices do
    begin
      if HasUdiLabel then WriteLn('UDI Label: ', UdiLabel);
      if HasUdiDeviceIdentifier then WriteLn('UDI Device Identifier: ', UdiDeviceIdentifier);
      if HasUdiIssuer then WriteLn('UDI Issuer: ', UdiIssuer);
      if HasUdiAuthority then WriteLn('UDI Authority: ', UdiAuthority);
    end;
  if Data.PresentFields = [] then WriteLn('Device Information Service has no known fields.');
end;

var
  Ble: TLazBleSync;
  Client: TBleClient;
  Information: TBleDeviceInformationProfile;
  Devices: TBleDeviceInfos;
  ErrorMessage: string;
begin
  if (ParamCount <> 1) or (ParamStr(1) = '--help') then
  begin
    WriteLn('Usage: ', ExtractFileName(ParamStr(0)), ' DEVICE_ID');
    WriteLn('Scans, connects, and prints the available Device Information fields.');
    if ParamCount <> 1 then ExitCode := 1;
    Exit;
  end;
  try
    Ble := TLazBleSync.Create;
    try
      if not Ble.Scan('', 5000, Devices, ErrorMessage) then
        raise Exception.Create('Scan failed: ' + ErrorMessage);
      Client := Ble.CreateClient(ParamStr(1));
      Information := TBleDeviceInformationProfile.Create;
      Client.AddProfile(Information);
      if not Ble.Connect(Client, 15000, ErrorMessage) then
        raise Exception.Create('Could not read Device Information: ' + ErrorMessage);
      PrintInformation(Information.Data);
    finally
      if not Ble.Shutdown(5000, ErrorMessage) then
      begin
        WriteLn(StdErr, 'Shutdown failed: ', ErrorMessage);
        ExitCode := 1;
      end;
      Ble.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, E.Message);
      ExitCode := 1;
    end;
  end;
end.
