unit LazBleLclRegister;

{$mode objfpc}{$H+}

interface

procedure Register;

implementation

uses
  Classes,
  LResources,
  LazBleComponent;

procedure Register;
begin
  RegisterComponents('LazBle', [
    TLazBleComponent,
    TLazBleLclClient
  ]);
end;

end.
