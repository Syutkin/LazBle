unit LazBleLclRegister;

{$mode objfpc}{$H+}

interface

procedure Register;

implementation

uses
  Classes,
  LResources,
  LazBleComponent,
  LazBleDeviceControl;

procedure Register;
begin
  RegisterComponents('LazBle', [
    TLazBleComponent,
    TLazBleLclClient,
    TLazBleDeviceControl
  ]);
end;

end.
