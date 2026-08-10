unit LazBleSimpleBleDriverIntf;

{$mode objfpc}{$H+}

interface

uses
  LazBleTypes;

type
  ILazBleSimpleBleDriverEventSink = interface
    ['{135F96C7-5434-4D4D-BE47-F97E450F69F8}']
    procedure Emit(const AEvent: TLazBleBackendEvent);
  end;

  ILazBleSimpleBleDriver = interface
    ['{27E5F79B-E4DD-42FB-A354-A3B992105970}']
    function Open(out AErrorMessage: string): Boolean;
    procedure Close;
    function Execute(const ACommand: TLazBleBackendCommand;
      const AOperationId: TBleOperationId;
      const AEventSink: ILazBleSimpleBleDriverEventSink;
      out AErrorCode: Integer; out AErrorMessage: string): Boolean;
    procedure CancelCurrent;
  end;

  ILazBleSimpleBleDriverSinkControl = interface
    ['{362FDEDF-71E8-41F4-9A80-B2AEBD634F22}']
    procedure Detach;
  end;

implementation

end.
