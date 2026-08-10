unit LazBleLclDemoForm;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  Forms,
  LazBleComponent,
  LazBleDeviceControl;

type
  TLazBleDemoForm = class(TForm)
    BleClient: TLazBleLclClient;
    BleDeviceControl: TLazBleDeviceControl;
    LazBle: TLazBleComponent;
  end;

var
  LazBleDemoForm: TLazBleDemoForm;

implementation

{$R *.lfm}

end.
