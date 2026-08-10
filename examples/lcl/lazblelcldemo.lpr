program LazBleLclDemo;

{$mode objfpc}{$H+}

uses
  Interfaces,
  Forms,
  LazBleLclDemoForm;

begin
  RequireDerivedFormResource := True;
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TLazBleDemoForm, LazBleDemoForm);
  Application.Run;
end.
