program fpmake;

{$mode objfpc}{$H+}

uses
  fpmkunit;

var
  Package: TPackage;
begin
  with Installer do
  begin
    Package := AddPackage('lazble');
    Package.Version := '0.1.0';
    Package.Author := 'Andrey Syutkin';
    Package.License := 'MIT';
    Package.Description :=
      'Asynchronous BLE Central and GATT Client library for Free Pascal';
    Package.SourcePath.Add('.');
    Package.SourcePath.Add('src');
    Package.SourcePath.Add('src/core');
    Package.Targets.AddUnit('lazbletypes.pas');
    Package.Targets.AddUnit('lazblebackend.pas');
    Package.Targets.AddUnit('lazblegattsession.pas');
    Package.Targets.AddUnit('lazblecentralmanager.pas');
    Package.Targets.AddUnit('lazble.pas');
    Run;
  end;
end.
