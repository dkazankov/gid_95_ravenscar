---------------------------------
-- GID - Generic Image Decoder --
---------------------------------
--
-- Private child of GID, with helpers for identifying
-- image formats and reading header informations.
--

with GID.Color_tables,
     GID.Decoding_PNG;

with Ada.Exceptions, Ada.Unchecked_Deallocation;

package body GID.Headers is

  use Ada.Exceptions;

  -------------------------------------------------------
  -- The very first: read signature to identify format --
  -------------------------------------------------------

  procedure Load_signature (
    image   :    out Image_descriptor;
    try_tga :        Boolean:= False

  )
  is
    use Bounded_255;
    c, d: Character;
    FITS_challenge: String(1..5); -- without the initial
    GIF_challenge : String(1..5); -- without the initial
    PNG_challenge : String(1..7); -- without the initial
    PNG_signature: constant String:=
      "PNG" & ASCII.CR & ASCII.LF & ASCII.SUB & ASCII.LF;
    procedure Dispose is
      new Ada.Unchecked_Deallocation(Color_table, p_Color_table);
  begin
    Dispose(image.palette);
    image.next_frame:= 0.0;
    Character'Read(image.stream, c);
    image.first_byte:= Character'Pos(c);
    case c is
      when 'B' =>
        Character'Read(image.stream, c);
        if c='M' then
          image.detailed_format:= To_Bounded_String("BMP");
          image.format:= BMP;
          return;
        end if;
      when 'S' =>
        String'Read(image.stream, FITS_challenge);
        if FITS_challenge = "IMPLE"  then
          image.detailed_format:= To_Bounded_String("FITS");
          image.format:= FITS;
          return;
        end if;
      when 'G' =>
        String'Read(image.stream, GIF_challenge);
        if GIF_challenge = "IF87a" or GIF_challenge = "IF89a" then
          image.detailed_format:= To_Bounded_String('G' & GIF_challenge & ", ");
          image.format:= GIF;
          return;
        end if;
      when 'I' | 'M' =>
        Character'Read(image.stream, d);
        if c=d then
          if c = 'I' then
            image.detailed_format:= To_Bounded_String("TIFF, little-endian");
          else
            image.detailed_format:= To_Bounded_String("TIFF, big-endian");
          end if;
          image.format:= TIFF;
          return;
        end if;
      when Character'Val(16#FF#) =>
        Character'Read(image.stream, c);
        if c=Character'Val(16#D8#) then
          image.detailed_format:= To_Bounded_String("JPEG");
          image.format:= JPEG;
          return;
        end if;
      when Character'Val(16#89#) =>
        String'Read(image.stream, PNG_challenge);
        if PNG_challenge = PNG_signature  then
          image.detailed_format:= To_Bounded_String("PNG");
          image.format:= PNG;
          return;
        end if;
      when others =>
        if try_tga then
          image.detailed_format:= To_Bounded_String("TGA");
          image.format:= TGA;
          return;
        else
          raise unknown_image_format;
        end if;
    end case;
    raise unknown_image_format;
  end Load_signature;

  generic
    type Number is mod <>;
  procedure Read_Intel_x86_number(
    from : in     Stream_Access;
    n    :    out Number
  );
    pragma Inline(Read_Intel_x86_number);

  generic
    type Number is mod <>;
  procedure Big_endian_number(
    from : in     Stream_Access;
    n    :    out Number
  );
    pragma Inline(Big_endian_number);

  procedure Read_Intel_x86_number(
    from : in     Stream_Access;
    n    :    out Number
  )
  is
    b: U8;
    m: Number:= 1;
  begin
    n:= 0;
    for i in 1..Number'Size/8 loop
      U8'Read(from, b);
      n:= n + m * Number(b);
      m:= m * 256;
    end loop;
  end Read_Intel_x86_number;

  procedure Big_endian_number(
    from : in     Stream_Access;
    n    :    out Number
  )
  is
    b: U8;
  begin
    n:= 0;
    for i in 1..Number'Size/8 loop
      U8'Read(from, b);
      n:= n * 256 + Number(b);
    end loop;
  end Big_endian_number;

  procedure Read_Intel is new Read_Intel_x86_number( U16 );
  procedure Read_Intel is new Read_Intel_x86_number( U32 );
  procedure Big_endian is new Big_endian_number( U32 );

  ----------------------------------------------------------
  -- Loading of various format's headers (past signature) --
  ----------------------------------------------------------

  ----------------
  -- BMP header --
  ----------------

  procedure Load_BMP_header (image: in out Image_descriptor) is
    file_size, offset, info_header, n, dummy: U32;
    pragma Warnings(off, dummy);
    w, dummy16: U16;
  begin
    --   Pos= 3, read the file size
    Read_Intel(image.stream, file_size);
    --   Pos= 7, read four bytes, unknown
    Read_Intel(image.stream, dummy);
    --   Pos= 11, read four bytes offset, file top to bitmap data.
    --            For 256 colors, this is usually 36 04 00 00
    Read_Intel(image.stream, offset);
    --   Pos= 15. The beginning of Bitmap information header.
    --   Data expected:  28H, denoting 40 byte header
    Read_Intel(image.stream, info_header);
    --   Pos= 19. Bitmap width, in pixels.  Four bytes
    Read_Intel(image.stream, n);
    image.width:=  Natural(n);
    --   Pos= 23. Bitmap height, in pixels.  Four bytes
    Read_Intel(image.stream, n);
    image.height:= Natural(n);
    --   Pos= 27, skip two bytes.  Data is number of Bitmap planes.
    Read_Intel(image.stream, dummy16); -- perform the skip
    --   Pos= 29, Number of bits per pixel
    --   Value 8, denoting 256 color, is expected
    Read_Intel(image.stream, w);
    case w is
      when 1 | 4 | 8 | 24 =>
        null;
      when others =>
        Raise_exception(
          unsupported_image_subformat'Identity,
          "bit depth =" & U16'Image(w)
        );
    end case;
    image.bits_per_pixel:= Integer(w);
    --   Pos= 31, read four bytes
    Read_Intel(image.stream, n);          -- Type of compression used
    -- BI_RLE8 = 1
    -- BI_RLE4 = 2
    if n /= 0 then
      Raise_exception(
        unsupported_image_subformat'Identity,
        "RLE compression"
      );
    end if;
    --
    Read_Intel(image.stream, dummy); -- Pos= 35, image size
    Read_Intel(image.stream, dummy); -- Pos= 39, horizontal resolution
    Read_Intel(image.stream, dummy); -- Pos= 43, vertical resolution
    Read_Intel(image.stream, n); -- Pos= 47, number of palette colors
    if image.bits_per_pixel <= 8 then
      if n = 0 then
        image.palette:= new Color_Table(0..2**image.bits_per_pixel-1);
      else
        image.palette:= new Color_Table(0..Natural(n)-1);
      end if;
    end if;
    Read_Intel(image.stream, dummy); -- Pos= 51, number of important colors
    --   Pos= 55 (36H), - start of palette
    Color_tables.Load_palette(image);
  end Load_BMP_header;

  procedure Load_FITS_header (image: in out Image_descriptor) is
  begin
    raise known_but_unsupported_image_format; -- !!
  end Load_FITS_header;

  ----------------
  -- GIF header --
  ----------------

  procedure Load_GIF_header (image: in out Image_descriptor) is
    -- GIF - logical screen descriptor
    screen_width, screen_height          : U16;
    packed, background, aspect_ratio_code : U8;
    global_palette: Boolean;
  begin
    Read_Intel(image.stream, screen_width);
    Read_Intel(image.stream, screen_height);
    image.width:= Natural(screen_width);
    image.height:= Natural(screen_height);
    U8'Read(image.stream, packed);
    --  Global Color Table Flag       1 Bit
    --  Color Resolution              3 Bits
    --  Sort Flag                     1 Bit
    --  Size of Global Color Table    3 Bits
    global_palette:= (packed and 16#80#) /= 0;
    image.bits_per_pixel:= Natural((packed and 16#7F#)/16#10#) + 1;
    -- Indicative:
    -- iv) [...] This value should be set to indicate the
    --     richness of the original palette
    U8'Read(image.stream, background);
    U8'Read(image.stream, aspect_ratio_code);
    if global_palette then
      image.subformat_id:= 1+(Natural(packed and 16#07#));
      -- palette's bits per pixels, usually <= image's
      --
      --  if image.subformat_id > image.bits_per_pixel then
      --    Raise_exception(
      --      error_in_image_data'Identity,
      --      "GIF: global palette has more colors than the image" &
      --       image.subformat_id'img & image.bits_per_pixel'img
      --    );
      --  end if;
      image.palette:= new Color_Table(0..2**(image.subformat_id)-1);
      Color_tables.Load_palette(image);
    end if;
  end Load_GIF_header;

  procedure Load_JPEG_header (image: in out Image_descriptor) is
  begin
    raise known_but_unsupported_image_format; -- !!
  end Load_JPEG_header;

  ----------------
  -- PNG header --
  ----------------

  procedure Load_PNG_header (image: in out Image_descriptor) is
    use Decoding_PNG;
    ch: Chunk_head;
    n, dummy: U32;
    pragma Warnings(off, dummy);
    b, color_type: U8;
    palette: Boolean:= False;
  begin
    Read(image, ch);
    if ch.kind /= IHDR then
      Raise_exception(
        error_in_image_data'Identity,
        "Expected 'IHDR' chunk in PNG stream"
      );
    end if;
    Big_endian(image.stream, n);
    image.width:=  Natural(n);
    Big_endian(image.stream, n);
    image.height:= Natural(n);
    U8'Read(image.stream, b);
    image.bits_per_pixel:= Integer(b);
    U8'Read(image.stream, color_type);
    image.subformat_id:= Integer(color_type);
    case color_type is
      when 0 => -- Greyscale
        image.greyscale:= True;
        case image.bits_per_pixel is
          when 1 | 2 | 4 | 8 | 16 =>
            null;
          when others =>
            Raise_exception(
              error_in_image_data'Identity,
              "PNG: wrong bit-per-channel depth"
            );
        end case;
      when 2 => -- RGB TrueColor
        case image.bits_per_pixel is
          when 8 | 16 =>
            image.bits_per_pixel:= 3 * image.bits_per_pixel;
          when others =>
            Raise_exception(
              error_in_image_data'Identity,
              "PNG: wrong bit-per-channel depth"
            );
        end case;
      when 3 => -- RGB with palette
        palette:= True;
        case image.bits_per_pixel is
          when 1 | 2 | 4 | 8 =>
            null;
          when others =>
            Raise_exception(
              error_in_image_data'Identity,
              "PNG: wrong bit-per-channel depth"
            );
        end case;
      when 4 => -- Grey & Alpha
        image.greyscale:= True;
        image.transparency:= True;
        case image.bits_per_pixel is
          when 8 | 16 =>
            image.bits_per_pixel:= 2 * image.bits_per_pixel;
          when others =>
            Raise_exception(
              error_in_image_data'Identity,
              "PNG: wrong bit-per-channel depth"
            );
        end case;
      when 6 => -- RGBA
        image.transparency:= True;
        case image.bits_per_pixel is
          when 8 | 16 =>
            image.bits_per_pixel:= 4 * image.bits_per_pixel;
          when others =>
            Raise_exception(
              error_in_image_data'Identity,
              "PNG: wrong bit-per-channel depth"
            );
        end case;
      when others =>
        Raise_exception(
          error_in_image_data'Identity,
          "Unknown PNG color type"
        );
    end case;
    U8'Read(image.stream, b);
    if b /= 0 then
      Raise_exception(
        error_in_image_data'Identity,
        "Unknown PNG compression; ISO/IEC 15948:2003" &
        " knows only 'method 0' (deflate)"
      );
    end if;
    U8'Read(image.stream, b);
    if b /= 0 then
      Raise_exception(
        error_in_image_data'Identity,
        "Unknown PNG filtering; ISO/IEC 15948:2003 knows only 'method 0'"
      );
    end if;
    U8'Read(image.stream, b);
    image.interlaced:= b = 1; -- Adam7
    Big_endian(image.stream, dummy); -- Chunk's CRC
    if palette then
      loop
        Read(image, ch);
        case ch.kind is
          when IEND =>
            Raise_exception(
              error_in_image_data'Identity,
              "PNG: there must be a palette, found IEND"
            );
          when PLTE =>
            if ch.length rem 3 /= 0 then
              Raise_exception(
                error_in_image_data'Identity,
                "PNG: palette chunk byte length must be a multiple of 3"
              );
            end if;
            image.palette:= new Color_Table(0..Integer(ch.length/3)-1);
            Color_tables.Load_palette(image);
            Big_endian(image.stream, dummy); -- Chunk's CRC
            exit;
          when others =>
            -- skip chunk data and CRC
            for i in 1..ch.length + 4 loop
              U8'Read(image.stream, b);
            end loop;
        end case;
      end loop;
    end if;
  end Load_PNG_header;

  ------------------------
  -- TGA (Targa) header --
  ------------------------

  procedure Load_TGA_header (image: in out Image_descriptor) is
    -- TGA FILE HEADER, p.6
    --
    image_ID_length: U8; -- Field 1
    color_map_type : U8; -- Field 2
    image_type     : U8; -- Field 3
    -- Color Map Specification - Field 4
    first_entry_index   : U16; -- Field 4.1
    color_map_length    : U16; -- Field 4.2
    color_map_entry_size: U8;  -- Field 4.3
    -- Image Specification - Field 5
    x_origin: U16;
    y_origin: U16;
    image_width: U16;
    image_height: U16;
    pixel_depth: U8;
    image_descriptor: U8;
    --
    dummy: U8;
    base_image_type: Integer;
  begin
    -- Read the header
    image_ID_length:= image.first_byte;
    U8'Read(image.stream, color_map_type);
    U8'Read(image.stream, image_type);
    --   Color Map Specification - Field 4
    Read_Intel(image.stream, first_entry_index);
    Read_Intel(image.stream, color_map_length);
    U8'Read(image.stream, color_map_entry_size);
    --   Image Specification - Field 5
    Read_Intel(image.stream, x_origin);
    Read_Intel(image.stream, y_origin);
    Read_Intel(image.stream, image_width);
    Read_Intel(image.stream, image_height);
    U8'Read(image.stream, pixel_depth);
    U8'Read(image.stream, image_descriptor);
    -- Done.
    if color_map_type /= 0 then
      Raise_exception(
        unsupported_image_subformat'Identity,
        "TGA color map (palette) not yet supported"
      );
    end if;

    -- Image type:
    --      1 = 8-bit palette style
    --      2 = Direct [A]RGB image
    --      3 = grayscale
    --      9 = RLE version of Type 1
    --     10 = RLE version of Type 2
    --     11 = RLE version of Type 3
    --
    base_image_type:= U8'Pos(image_type and 7);
    image.RLE_encoded:= (image_type and 8) /= 0;
    image.greyscale:= False; -- ev. overridden later
    case base_image_type is
      when 2 =>
        null;
      when 3 =>
        image.greyscale:= True;
      when others =>
        Raise_exception(
          unsupported_image_subformat'Identity,
          "TGA type =" & Integer'Image(base_image_type)
        );
    end case;

    image.width  := U16'Pos(image_width);
    image.height := U16'Pos(image_height);
    image.bits_per_pixel := U8'Pos(pixel_depth);

    -- Make sure we are loading a supported TGA_type
    case image.bits_per_pixel is
      when 32 | 24 | 8 =>
        null;
      when others =>
        Raise_exception(
          unsupported_image_subformat'Identity,
          "Bits per pixels =" & Integer'Image(image.bits_per_pixel)
        );
    end case;
    --  *** Image and color map data
    --  * Image ID
    for i in 1..image_ID_length loop
      U8'Read( image.stream, dummy );
    end loop;
    --  * Color map data (palette)
    --  To be read when palette will be supporded; exception raise before.
    --  * Image data: Read by Load_image_contents.
  end Load_TGA_header;

  procedure Load_TIFF_header (image: in out Image_descriptor) is
  begin
    raise known_but_unsupported_image_format; -- !!
  end Load_TIFF_header;

end;
