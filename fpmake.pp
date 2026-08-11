program fpmake;

{$mode objfpc}{$H+}

uses
  fpmkunit;

var
  Package: TPackage;
  Dependency: TDependency;
begin
  with Installer do
  begin
    Package := AddPackage('lazble');
    Package.Version := '1.0.0';
    Package.Author := 'Andrey Syutkin';
    Package.License := 'MIT';
    Package.Description :=
      'Asynchronous BLE and GATT client library for Free Pascal';
    Package.Dependencies.Add('fcl-base');
    Dependency := Package.Dependencies.Add('simpleblepascal');
    Dependency.Version := '1.1.0';
    Package.SourcePath.Add('.');
    Package.SourcePath.Add('src');
    Package.SourcePath.Add('src/backends');
    Package.SourcePath.Add('src/core');
    Package.SourcePath.Add('src/profiles');
    Package.Targets.AddUnit('lazbletypes.pas');
    Package.Targets.AddUnit('lazblebackend.pas');
    Package.Targets.AddUnit('lazbleoperation.pas');
    Package.Targets.AddUnit('lazblegattoperation.pas');
    Package.Targets.AddUnit('lazblegattsubscription.pas');
    Package.Targets.AddUnit('lazblegattsession.pas');
    Package.Targets.AddUnit('lazblegattprofile.pas');
    Package.Targets.AddUnit('lazblebytechannel.pas');
    Package.Targets.AddUnit('lazblecentralmanager.pas');
    Package.Targets.AddUnit('lazbleclientinternal.pas');
    Package.Targets.AddUnit('lazbleclient.pas');
    Package.Targets.AddUnit('lazblereconnect.pas');
    Package.Targets.AddUnit('lazblefacade.pas');
    Package.Targets.AddUnit('lazblesync.pas');
    Package.Targets.AddUnit('lazblenus.pas');
    Package.Targets.AddUnit('lazblebattery.pas');
    Package.Targets.AddUnit('lazblesimplebledriverintf.pas');
    Package.Targets.AddUnit('lazblesimpleblebackend.pas');
    Package.Targets.AddUnit('lazble.pas');
    Run;
  end;
end.
