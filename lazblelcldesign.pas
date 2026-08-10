{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit LazBleLCLDesign;

{$warn 5023 off : no warning about unused units}
interface

uses
  LazBleLclRegister, LazarusPackageIntf;

implementation

procedure Register;
begin
  RegisterUnit('LazBleLclRegister', @LazBleLclRegister.Register);
end;

initialization
  RegisterPackage('LazBleLCLDesign', @Register);
end.
