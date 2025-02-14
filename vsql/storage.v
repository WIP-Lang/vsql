// storage.v handles storing all tables and records within a single file.
//
// This is extremely crude and inefficient. It'll do for an initial alpha.
// Opening an existing database requires reading the entire file to prepare the
// table definitions and any table scan also requires reading the entire file.
// Although, INSERTs, DELETEs and UPDATEs are O(1).

module vsql

import os

struct FileStorage {
	path string
mut:
	version i8
	f       os.File
	tables  map[string]Table
}

type FileStorageObject = Row | Table

struct FileStorageNextObject {
	is_eof   bool
	category int
	obj      FileStorageObject
}

fn new_file_storage(path string) ?FileStorage {
	// This is a rudimentary way to ensure that small changes to storage.v are
	// compatible as things change so rapidly. Sorry if you had a database in a
	// previous version, you'll need to recreate it.
	current_version := i8(2)

	// If the file doesn't exist we initialize it and reopen it.
	if !os.exists(path) {
		mut tmpf := os.create(path) ?
		tmpf.write_raw(current_version) ?
		tmpf.close()
	}

	// Now open the prepared or existing file and read all of the table
	// definitions.
	mut f := FileStorage{
		path: path
		f: os.open_file(path, 'r+') ?
	}

	f.version = f.read<i8>() ?
	if f.version != current_version {
		return error('need version $current_version but database is $f.version')
	}

	for {
		next := f.read_object() ?
		if next.is_eof {
			break
		}

		if next.obj is Table {
			f.tables[next.obj.name] = next.obj
		}
	}

	return f
}

fn (mut f FileStorage) read<T>() ?T {
	return f.f.read_raw<T>()
}

fn (mut f FileStorage) write<T>(x T) ? {
	f.f.write_raw<T>(x) ?
}

fn (mut f FileStorage) close() {
	f.f.close()
}

fn (mut f FileStorage) write_value(v Value) ? {
	f.write<SQLType>(v.typ.typ) ?

	match v.typ.typ {
		.is_null {}
		.is_boolean, .is_double_precision, .is_bigint, .is_integer, .is_real, .is_smallint {
			f.write<f64>(v.f64_value) ?
		}
		.is_varchar, .is_character {
			f.write<int>(v.string_value.len) ?
			for b in v.string_value.bytes() {
				f.write<byte>(b) ?
			}
		}
	}
}

fn (mut f FileStorage) read_value() ?Value {
	typ := f.read<SQLType>() ?

	return match typ {
		.is_null {
			new_null_value()
		}
		.is_boolean, .is_bigint, .is_double_precision, .is_real, .is_smallint, .is_integer {
			Value{
				typ: Type{typ, 0}
				f64_value: f.read<f64>() ?
			}
		}
		.is_varchar, .is_character {
			len := f.read<int>() ?
			mut buf := []byte{len: len}
			f.f.read(mut buf) ?

			// TODO(elliotchance): There seems to be a weird bug where
			//  converting some bytes to a string ends up with a string that
			//  also contains the NULL character. ie 'DOUBLE PRECISION' (16
			//  bytes) becomes 'DOUBLE PRECISION\0' (17 bytes). The [..buf.len]
			//  is a temporary protection against this.
			Value{
				typ: Type{typ, 0}
				string_value: string(buf)[..buf.len]
			}
		}
	}
}

fn sizeof_value(value Value) int {
	return int(sizeof(SQLType) + match value.typ.typ {
		.is_null { 0 }
		.is_boolean, .is_double_precision, .is_integer, .is_bigint, .is_smallint, .is_real { sizeof(f64) }
		.is_varchar, .is_character { sizeof(int) + u32(value.string_value.len) }
	})
}

fn (mut f FileStorage) write_object(category int, values []Value) ? {
	// Always ensure we append to the file.
	f.f.seek(0, .end) ?

	mut data_len := int(0)
	for value in values {
		data_len += sizeof_value(value)
	}

	f.write(data_len) ?
	f.write(category) ?

	for value in values {
		f.write_value(value) ?
	}
}

fn (mut f FileStorage) read_object() ?FileStorageNextObject {
	data_len := f.read<int>() or {
		// TODO(elliotchance): I'm not sure what the correcy way to detect EOF
		//  is, but let's assume this error means the end.
		return FileStorageNextObject{
			is_eof: true
		}
	}
	offset := u32(f.f.tell() ?)
	category := f.read<int>() ?

	mut values := []Value{}
	for i := 0; i < data_len; {
		value := f.read_value() ?
		values << value
		i += sizeof_value(value)
	}

	if category == 0 {
		return FileStorageNextObject{
			category: category
		}
	}

	if category >= 10000 {
		mut table := Table{}
		for _, t in f.tables {
			if t.index == category - 10000 {
				table = t
			}
		}

		mut i := 0
		mut row := Row{
			offset: offset
			data: map[string]Value{}
		}
		for column in table.columns {
			row.data[column.name] = values[i]
			i++
		}

		return FileStorageNextObject{
			category: category
			obj: row
		}
	}

	mut columns := []Column{cap: (values.len - 2) / 2}
	for i := 2; i < values.len; i += 2 {
		columns << Column{
			name: values[i].string_value
			typ: new_type(values[i + 1].string_value, 0)
		}
	}

	return FileStorageNextObject{
		category: category
		obj: Table{
			offset: offset
			index: int(values[0].f64_value)
			name: values[1].string_value
			columns: columns
		}
	}
}

fn (mut f FileStorage) create_table(table_name string, columns []Column) ? {
	mut values := []Value{}
	index := f.tables.len + 1
	offset := u32(f.f.tell() ?)

	// If index is 0, the table is deleletd
	values << new_double_precision_value(index)
	values << new_varchar_value(table_name, 0)

	for column in columns {
		values << new_varchar_value(column.name, 0)
		values << new_varchar_value(column.typ.str(), 0)
	}

	f.write_object(1, values) ?

	f.tables[table_name] = Table{offset, index, table_name, columns}
}

fn (mut f FileStorage) delete_table(table_name string) ? {
	f.f.seek(f.tables[table_name].offset, .start) ?

	// If index is 0, the table is deleted
	f.write_value(new_double_precision_value(0)) ?

	f.tables.delete(table_name)
}

fn (mut f FileStorage) delete_row(row Row) ? {
	f.f.seek(row.offset, .start) ?
	zero := 0
	f.write<int>(zero) ?
}

fn (mut f FileStorage) write_row(r Row, t Table) ? {
	mut values := []Value{}
	for column in t.columns {
		values << r.data[column.name]
	}
	f.write_object(10000 + t.index, values) ?
}

fn (mut f FileStorage) read_rows(table_index int, offset int) ?[]Row {
	f.f.seek(1, .start) ?

	mut rows := []Row{}
	mut skipped := 0
	for {
		next := f.read_object() ?
		if next.is_eof {
			break
		}

		if next.obj is Row && next.category - 10000 == table_index {
			if skipped < offset {
				skipped++
			} else {
				rows << next.obj
			}
		}
	}

	return rows
}
