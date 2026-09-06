import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';
import 'package:test/test.dart';

const Map<String, String> kHelpOracleTerminals = {
  'Add': '<x|<y|>x+y',
  'Subtract': '<x|<y|>x-y',
  'Multiply': '<x|<y|>x*y',
  'Divide': '<x|<y|>x/y',
  'Quotient & Remainder': '<x|<y|>x-y*floor(x/y)|>floor(x/y)',
  'Increment': '<x|>x+1',
  'Decrement': '<x|>x-1',
  'Square Root': '<x|>sqrt(x)',
  'And': '<x|<y|>x .and. y?',
  'Or': '<x|<y|>x .or. y?',
  'Exclusive Or': '<x|<y|>x .xor. y?',
  'Not': '<x|>.not. x?',
  'Random Number (0-1)': '>number (0 to 1)',
  'Path To String': '<path|>string',
  'String To Path': '<string|>path',
  'Logical Shift': '<y|<x|>x << y',
  'First Call?': '>First Call?',
  'Equal?': '<x|<y|>',
  'Not Equal?': '<x|<y|>x!=y?',
  'Max & Min': '<x|<y|>max(x, y)|>min(x, y)',
  'Greater?': '<x|<y|>x > y?',
  'Less?': '<x|<y|>x < y?',
  'Empty String/Path?': '<string/path|>empty?',
  'Equal To 0?': '<x|>x = 0?',
  'Greater Or Equal To 0?': '<x|>x >= 0?',
  'Less Or Equal To 0?': '<x|>x <= 0?',
  'Not Equal To 0?': '<x|>x!= 0?',
  'Greater Than 0?': '<x|>x > 0?',
  'Less Than 0?': '<x|>x < 0?',
  'Sort 1D Array': '<array|>sorted array',
  'In Range and Coerce': '<upper limit|<x|<|>coerced(x)|>In Range?',
  'Not A Number/Path/Refnum?': '<number/path/refnum|>NaN/Path/Refnum?',
  'To Byte Integer': '<number|>8bit integer',
  'To Word Integer': '<number|>16bit integer',
  'To Long Integer': '<number|>32bit integer',
  'To Unsigned Byte Integer': '<number|>unsigned 8bit integer',
  'To Unsigned Word Integer': '<number|>unsigned 16bit integer',
  'To Unsigned Long Integer': '<number|>unsigned 32bit integer',
  'To Single Precision Float': '<number|>single precision float',
  'To Double Precision Float': '<number|>double precision float',
  'To Quad Integer': '<number|>64bit integer',
  'To Unsigned Quad Integer': '<number|>unsigned 64bit integer',
  'Swap Bytes': '<data|>byte swapped',
  'Swap Words': '<data|>word swapped',
  'Flatten To String':
      '<anything|<prepend array or string size?|<byte order|<error in|>data string|>type string (7.x only)|>error out',
  'Type Cast': '<type|<x|>*(type *) &x',
  'Boolean To (0,1)': '<Boolean|>0, 1',
  'Cluster To Array': '<|>',
  'Number To Decimal String': '<number|<width|>decimal integer string',
  'Decimal String To Number': '<string|<offset|<default|>offset past number|>number',
  'To Lower Case': '<string|>all lower case string',
  'Tick Count (ms)': '>millisecond timer value',
  'Wait (ms)': '<milliseconds to wait|>millisecond timer value',
  'Get Date/Time In Seconds': '>current time',
  'Wait Until Next ms Multiple': '<millisecond multiple|>millisecond timer value',
  'One Button Dialog': '<message|<button name|>true',
  'Two Button Dialog': '<message|<T button name|<F button name|>T button?',
  'Build Path': '<base path|<name or relative path|>appended path',
  'Strip Path': '<path|>stripped path|>name',
  'VI Library': '>path',
  'Current VI\'s Path': '>path',
  'String Length': '<string|>length',
  'String Subset': '<string|<offset|<length|>substring',
  'Pick Line': '<string|<multi-line string|<line index|>output string',
  'Select': '<t|<s|<f|>s? t:f',
  'Match Pattern':
      '<string|<regular expression|<offset|>before substring|>match substring|>after substring|>offset past match',
  'Search/Split String':
      '<string|<search string/char|<offset|>substring before match|>match + rest of string|>offset of match',
  'Spreadsheet String To Array': '<delimiter|<format string|<spreadsheet string|<array type|>array',
  'Array To Spreadsheet String': '<delimiter|<format string|<array|>spreadsheet string',
  'Rotate Left With Carry': '<carry|<value|>msb carry out|>value',
  'Rotate Right With Carry': '<carry|<value|>lsb carry out|>value',
  'String To Byte Array': '<string|>unsigned byte array',
  'Byte Array To String': '<unsigned byte array|>string',
  'Array Size': '<array|>size(s)',
  'Number To Boolean Array': '<number|>Boolean array',
  'Boolean Array To Number': '<Boolean array|>number',
  'Reverse 1D Array': '<array|>reversed array',
  'Search 1D Array': '<1D array|<element|<start index|>index of element',
  'Transpose 2D Array': '<2D array|>transposed array',
  'Add Array Elements': '<numeric array|>sum',
  'Array Max & Min': '<array|>max value|>max index(es)|>min value|>min index(es)',
  'Or Array Elements': '<Boolean array|>logical OR',
  'And Array Elements': '<Boolean array|>logical AND',
  'Call Chain': '>call chain',
  'Create User Event': '<user event data type|<error in|>user event out|>error out',
  'Generate User Event': '<priority|<user event|<event data|<error in|>user event out|>error out',
  'Destroy User Event': '<user event|<|>error out',
  'Unregister For Events': '<event registration refnum|<error in|>error out',
  'New Data Value Reference': '<data value|<error in|>data value reference|>error out',
  'Delete Data Value Reference': '<data value reference|<error in|>data value|>error out',
  'Search and Replace String':
      '<multiline?|<ignore case?|<replace all?|<input string|<search string|<replace string|<offset|<error in|>result string|>number of replacements|>offset past replacement|>error out',
  'Variant To Data': '<type|<variant|<error in|>data|>error out',
  'Open VI Reference':
      '<type specifier VI Refnum (for type only)|<application reference|<vi path|<|<error in|<password|>vi reference|>error out',
  'Close Reference': '<reference|<error in|>error out',
  'New VI Object':
      '<auto wire?|<vi object class|<owner refnum|<style|<location|<error in|<path|<bounds|>object refnum|>error out',
  'To More Specific Class': '<target class|<reference|<error in|>specific class reference|>error out',
  'Open/Create/Replace File':
      '<prompt|<file path|<operation|<access|<error in|<disable buffering|>refnum out|>cancelled|>error out',
  'Close File': '<refnum|<|>path|>error out',
  'Create Folder': '<prompt (Create Folder)|<path|<error in|>created path|>cancelled|>error out',
  'Delete': '<prompt|<path|<entire hierarchy|<|<error in|>deleted path|>cancelled|>error out',
  'Get File Size': '<file|<error in|>refnum out|>size (in bytes)|>error out',
  'Read from Text File': '<prompt|<file|<count|<error in|>refnum out|>text|>cancelled|>error out',
  'Set File Position': '<refnum|<offset (in bytes)|<from|<error in|>refnum out|>error out',
  'Write to Text File': '<prompt|<file|<text|<error in|>refnum out|>cancelled|>error out',
  'File/Directory Info': '<path|<error in|>directory|>path out|>size|>last mod|>error out|>resolved path|>shortcut',
  'Format Date/Time String': '<time format string|<time stamp|<UTC format|>date/time string',
  'To Variant': '<anything|>variant',
  'Variant To Flattened String': '<variant|>type string|>data string',
  'Set Variant Attribute': '<variant|<name|<value|<error in|>variant out|>replaced|>error out',
  'Get Variant Attribute': '<variant|<name|<default value|<error in|>duplicate variant|>names|>values|>error out',
  'Current VI\'s Menubar': '>menu reference',
  'Send Notification': '<notifier|<notification|<error in|>notifier out|>error out',
  'Wait on Notification':
      '<notifier|<ignore previous|<timeout in ms|<error in|>notifier out|>notification|>timed out?|>error out',
  'Obtain Queue':
      '<max queue size|<name|<element data type|<create if not found?|<error in|>queue out|>created new?|>error out',
  'Release Queue': '<queue|<force destroy?|<|>queue name|>remaining elements|>error out',
  'Get Queue Status':
      '<queue|<return elements?|<error in|>max queue size|>queue name|>queue out|># pending remove|># pending insert|>error out|># elements in queue|>elements',
  'Enqueue Element': '<queue|<element|<timeout in ms|<error in|>queue out|>timed out?|>error out',
  'Empty Array?': '<array|>empty?',
  'Flatten To JSON': '<enable LabVIEW extensions|<anything|<error in|>JSON string|>error out',
};
const Set<String> kHelpOracleUncorroborated = {'File Dialog', 'VISA Lock'};

void main() {
  test('the published reference corroborates the catalogue name for name', () {
    expect(
      {for (final op in PrimOp.values) op.opName}.difference(kHelpOracleTerminals.keys.toSet()),
      kHelpOracleUncorroborated,
    );
    expect(PrimOp.values.length, kHelpOracleTerminals.length + kHelpOracleUncorroborated.length);
  });

  test('every primitive with a lowering rule is one the reference corroborates', () {
    for (final op in kLvMappedPrimOps) {
      expect(kHelpOracleTerminals[op.opName], isNotNull, reason: '${op.id} ${op.opName}');
    }
  });
}
