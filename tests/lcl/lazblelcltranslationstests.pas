unit LazBleLclTranslationsTests;

{$mode objfpc}{$H+}

interface

uses
  FpcUnit,
  TestRegistry;

type
  TLazBleLclTextSnapshot = record
    FormCaption: string;
    NameColumnCaption: string;
    DeviceIdColumnCaption: string;
    StatusCaption: string;
    StartButtonCaption: string;
    SelectButtonCaption: string;
    CancelButtonCaption: string;
  end;

  TLazBleLclTranslationsTest = class(TTestCase)
  published
    procedure CatalogueSwitchChangesAndRestoresLclControls;
  end;

implementation

uses
  SysUtils,
  LazFileUtils,
  LazUTF8,
  LazBleDeviceSelectForm,
  LazBleLclTranslations;

function LanguageDirectory: string;
begin
  Result := ExpandFileNameUTF8(ExtractFilePath(ParamStrUTF8(0)) + '..' +
    DirectorySeparator + '..' + DirectorySeparator + 'languages');
end;

function CaptureLclText: TLazBleLclTextSnapshot;
var
  DeviceSelectForm: TBleDeviceSelectForm;
begin
  DeviceSelectForm := TBleDeviceSelectForm.Create(nil);
  try
    Result.FormCaption := DeviceSelectForm.Caption;
    Result.NameColumnCaption :=
      DeviceSelectForm.DeviceGrid.Columns[0].Title.Caption;
    Result.DeviceIdColumnCaption :=
      DeviceSelectForm.DeviceGrid.Columns[1].Title.Caption;
    Result.StatusCaption := DeviceSelectForm.StatusLabel.Caption;
    Result.StartButtonCaption := DeviceSelectForm.ButtonStart.Caption;
    Result.SelectButtonCaption := DeviceSelectForm.ButtonSelect.Caption;
    Result.CancelButtonCaption := DeviceSelectForm.ButtonCancel.Caption;
  finally
    DeviceSelectForm.Free;
  end;
end;

procedure TLazBleLclTranslationsTest.CatalogueSwitchChangesAndRestoresLclControls;
var
  EnglishText: TLazBleLclTextSnapshot;
  RestoredText: TLazBleLclTextSnapshot;
  TranslatedText: TLazBleLclTextSnapshot;
begin
  TranslateLazBleLclResourceStrings(LanguageDirectory, 'en', '');
  EnglishText := CaptureLclText;
  TranslateLazBleLclResourceStrings(LanguageDirectory, 'ru', 'en');
  try
    TranslatedText := CaptureLclText;
    AssertTrue('Form caption was not translated',
      TranslatedText.FormCaption <> EnglishText.FormCaption);
    AssertTrue('Name column was not translated',
      TranslatedText.NameColumnCaption <> EnglishText.NameColumnCaption);
    AssertTrue('Device ID column was not translated',
      TranslatedText.DeviceIdColumnCaption <> EnglishText.DeviceIdColumnCaption);
    AssertTrue('Status was not translated',
      TranslatedText.StatusCaption <> EnglishText.StatusCaption);
    AssertTrue('Start button was not translated',
      TranslatedText.StartButtonCaption <> EnglishText.StartButtonCaption);
    AssertTrue('Select button was not translated',
      TranslatedText.SelectButtonCaption <> EnglishText.SelectButtonCaption);
    AssertTrue('Cancel button was not translated',
      TranslatedText.CancelButtonCaption <> EnglishText.CancelButtonCaption);
  finally
    TranslateLazBleLclResourceStrings(LanguageDirectory, 'en', '');
  end;

  RestoredText := CaptureLclText;
  AssertEquals(EnglishText.FormCaption, RestoredText.FormCaption);
  AssertEquals(EnglishText.NameColumnCaption, RestoredText.NameColumnCaption);
  AssertEquals(EnglishText.DeviceIdColumnCaption,
    RestoredText.DeviceIdColumnCaption);
  AssertEquals(EnglishText.StatusCaption, RestoredText.StatusCaption);
  AssertEquals(EnglishText.StartButtonCaption,
    RestoredText.StartButtonCaption);
  AssertEquals(EnglishText.SelectButtonCaption,
    RestoredText.SelectButtonCaption);
  AssertEquals(EnglishText.CancelButtonCaption,
    RestoredText.CancelButtonCaption);
end;

initialization
  RegisterTest(TLazBleLclTranslationsTest);

end.
