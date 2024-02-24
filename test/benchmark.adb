with GID,
     Comp_Img_Fct;

with Ada.Calendar,
     Ada.Characters.Handling,
     Ada.Containers.Indefinite_Hashed_Maps,
     Ada.Containers.Vectors,
     Ada.Streams.Stream_IO,
     Ada.Strings.Hash,
     Ada.Text_IO,
     Ada.Unchecked_Deallocation;

with Interfaces.C;

procedure Benchmark is

  use Ada.Characters.Handling, Ada.Streams.Stream_IO, Ada.Text_IO, Interfaces;

  procedure Blurb is
  begin
    Put_Line ("Benchmark for the GID (Generic Image Decoder) package");
    Put_Line ("Package version " & GID.version & " dated " & GID.reference);
    Put_Line ("URL: " & GID.web);
    New_Line;
    Put_Line ("GID is compared against results of ImageMagick ( https://imagemagick.org/ ).");
    Put_Line ("The executable magick needs to be visible on the path.");
    New_Line;
    Put_Line ("Syntax:");
    Put_Line ("benchmark");
    New_Line;
    Put_Line ("In order to save your SDD / Hard Disk and to minimize file transaction times,");
    Put_Line ("it is recommended to copy the images (in ./test/img) to a RAM Disk");
    Put_Line ("and run the program there.");
    New_Line;
  end Blurb;

  --  The following code is copy-pasted from mini.adb.

  type Byte_Array is array (Integer range <>) of Unsigned_8;
  type p_Byte_Array is access Byte_Array;
  procedure Dispose is new Ada.Unchecked_Deallocation (Byte_Array, p_Byte_Array);

  img_buf : p_Byte_Array := null;

  force_allocate : constant := -1;
  mem_buffer_last : Integer;

  --  Load image into a 24-bit truecolor RGB raw bitmap (for a PPM output)
  procedure Load_Raw_Image
    (image : in out GID.Image_Descriptor;
     buffer : in out p_Byte_Array;
     next_frame : out Ada.Calendar.Day_Duration)
  is
    subtype Primary_Color_Range is Unsigned_8;
    image_width  : constant Positive := GID.Pixel_Width (image);
    image_height : constant Positive := GID.Pixel_Height (image);
    idx : Natural;
    --
    procedure Set_X_Y (x, y : Natural) is
    begin
      idx := 3 * (x + image_width * (image_height - 1 - y));
    end Set_X_Y;
    --
    procedure Put_Pixel
      (red, green, blue : Primary_Color_Range;
       alpha            : Primary_Color_Range)
    is
    pragma Warnings (off, alpha);  --  Alpha is just ignored
    begin
      buffer (idx .. idx + 2) := (red, green, blue);
      idx := idx + 3;
      --  ^ GID requires us to look to next pixel on the right for next time.
    end Put_Pixel;

    stars : Natural := 0;
    procedure Feedback (percents : Natural) is
      so_far : constant Natural := percents / 10;
    begin
      for i in stars + 1 .. so_far loop
        Put ('*');
      end loop;
      stars := so_far;
    end Feedback;

    procedure Load_Image is
      new GID.Load_Image_Contents
        (Primary_Color_Range, Set_X_Y,
         Put_Pixel, Feedback, GID.fast);

    buffer_last : Natural;

  begin
    buffer_last := 3 * image_width * image_height - 1;
    if buffer_last /= mem_buffer_last then
      Dispose (buffer);
      buffer := new Byte_Array (0 .. buffer_last);
      mem_buffer_last := buffer_last;
    end if;
    Load_Image (image, next_frame);
  end Load_Raw_Image;

  procedure Dump_PPM (name : String; i : GID.Image_Descriptor) is
    f : Ada.Streams.Stream_IO.File_Type;
  begin
    Create (f, Out_File, name);
    --  PPM Header:
    String'Write
      (Stream (f),
       "P6 " & GID.Pixel_Width (i)'Image & GID.Pixel_Height (i)'Image &
       " 255" & ASCII.LF);
    --  PPM raw BGR image:
    declare
      --  Workaround for the severe xxx'Read xxx'Write performance
      --  problems in the GNAT and ObjectAda compilers (as in 2009)
      --  This is possible if and only if Byte = Stream_Element and
      --  arrays types are both packed the same way.
      --
      subtype Size_test_a is Byte_Array (1 .. 19);
      subtype Size_test_b is Ada.Streams.Stream_Element_Array (1 .. 19);
      workaround_possible : constant Boolean :=
        Size_test_a'Size = Size_test_b'Size and then
        Size_test_a'Alignment = Size_test_b'Alignment;
      --
    begin
      if workaround_possible then
        declare
          use Ada.Streams;
          SE_Buffer   : Stream_Element_Array (0 .. Stream_Element_Offset (img_buf'Length - 1));
          for SE_Buffer'Address use img_buf.all'Address;
          pragma Import (Ada, SE_Buffer);
        begin
          Ada.Streams.Write (Stream (f).all, SE_Buffer (0 .. Stream_Element_Offset (img_buf'Length - 1)));
        end;
      else
        Byte_Array'Write (Stream (f), img_buf.all); -- the workaround is about this line...
      end if;
    end;
    Close (f);
  end Dump_PPM;

  package Name_Maps is new Ada.Containers.Indefinite_Hashed_Maps
    (Key_Type        => String,
     Element_Type    => Positive,
     Hash            => Ada.Strings.Hash,
     Equivalent_Keys => "=");

  type Stats_Row is record
    cumulative_duration_gid   : Duration   := 0.0;
    cumulative_duration_other : Duration   := 0.0;
    difference_score          : Long_Float := 0.0;
    occ_per_category          : Natural    := 0;  --  For single image: 1.
  end record;

  package Stats_Vectors is new Ada.Containers.Vectors
    (Index_Type   => Positive,
     Element_Type => Stats_Row);

  stats_table : Stats_Vectors.Vector;

  image_stats,
  format_stats,
  format_subformat_stats : Name_Maps.Map;

  procedure Process (name : String) is
    f : Ada.Streams.Stream_IO.File_Type;
    i : GID.Image_Descriptor;
    up_name : constant String := To_Upper (name);
    --
    next_frame : Ada.Calendar.Day_Duration := 0.0;
    --
    function GNAT_Sys (Arg : Interfaces.C.char_array) return Interfaces.C.int;
    pragma Import (C, GNAT_Sys, "system");

    procedure Sys (Command : String; Result : out Integer) is
      --  https://rosettacode.org/wiki/Execute_a_system_command#Ada
    begin
      Result := Integer (GNAT_Sys (Interfaces.C.To_C (Command)));
    end Sys;

    use Ada.Calendar;
    res : Integer;
    T0, T1, T2 : Time;
    dur_gid, dur_magick : Duration;

    gid_name    : constant String := name & "_gid.ppm";
    magick_name : constant String := name & "_magick.ppm";

    dist : Long_Float;

    procedure Feed_Stat (stat_map : in out Name_Maps.Map; stat_name : String) is
      procedure Feed_To (the_row : in out Stats_Row) is
      begin
        the_row.cumulative_duration_gid   := the_row.cumulative_duration_gid + dur_gid;
        the_row.cumulative_duration_other := the_row.cumulative_duration_other + dur_magick;
        the_row.difference_score          := the_row.difference_score + dist;
        the_row.occ_per_category          := the_row.occ_per_category + 1;
      end Feed_To;
    begin
      if not stat_map.Contains (stat_name) then
        declare
          new_row : Stats_Row;
        begin
          stats_table.Append (new_row);
          stat_map.Insert (stat_name, stats_table.Last_Index);
        end;
      end if;
      Feed_To (stats_table (stat_map.Element (stat_name)));
    end Feed_Stat;

  begin
    --
    --  Load the image in its original format
    --
    Open (f, In_File, "img/" & name);
    Put ("Processing " & name & "... ");
    T0 := Clock;
    --
    GID.Load_Image_Header
      (i,
       Stream (f).all,
       try_tga =>
         name'Length >= 4 and then
         up_name (up_name'Last - 3 .. up_name'Last) = ".TGA");
    --
    mem_buffer_last := force_allocate;
    Load_Raw_Image (i, img_buf, next_frame);
    Dump_PPM ("img/" & gid_name, i);
    New_Line;
    --
    Close (f);
    T1 := Clock;
    --
    --  Call the other tool.
    --
    Sys ("magick img/" & name & " img/" & magick_name, res);
    if res /= 0 then
      Put_Line ("Error calling magick!");
      raise Program_Error;
    end if;
    T2 := Clock;
    dur_gid    := T1 - T0;
    dur_magick := T2 - T1;
    Put
      ("Durations: GID:" & dur_gid'Image &
       ", Magick:" & dur_magick'Image & "; difference score:");
    dist := Comp_Img_Fct ("img/" & gid_name, "img/" & magick_name, False);
    Put_Line (dist'Image);
    New_Line;
    --
    Feed_Stat (image_stats, name);
    Feed_Stat (format_stats, GID.Format (i)'Image);
    Feed_Stat
      (format_subformat_stats,
       GID.Format (i)'Image & ' ' &
       GID.Detailed_format (i) &
       " Subformat" & GID.Subformat (i)'Image);
  end Process;

  iterations : constant := 100;

  procedure Show_Stats (categ_map : Name_Maps.Map) is
    procedure Row_Details (row : Stats_Row) is
      denom : constant Integer := iterations * row.occ_per_category;
    begin
      Put_Line ("   Images in this category      : " & row.occ_per_category'Image);
      Put_Line ("   Average duration GID         : " &
        Duration'Image (row.cumulative_duration_gid / denom));
      Put_Line ("   Average duration ImageMagick : " &
        Duration'Image (row.cumulative_duration_other / denom));
      Put_Line ("   Average difference score     : " &
        Long_Float'Image (row.difference_score / Long_Float (row.occ_per_category)));
      New_Line;
    end Row_Details;
  begin
    New_Line;
    for curs in categ_map.Iterate loop
      Put_Line (Name_Maps.Key (curs));
      Row_Details (stats_table (Name_Maps.Element (curs)));
    end loop;
  end Show_Stats;

begin
  Blurb;
  delay 4.0;
  
  --  !! Here, add a loop for comparing the decoding of a tiny image,
  --     in order to discount the invocation time of the external program. 
  
  for iter in 1 .. iterations loop
    for row of stats_table loop
      row.occ_per_category := 0;
      row.difference_score := 0.0;
      --  ^ same for each iteration, so we avoid cumulating rounding errors uselessly.
    end loop;
    Put_Line ("---------------------------- Iteration" & iter'Image);
    Process ("gif_interlaced_hifi.gif");
    Process ("gif_non_interlaced_hifi.gif");
    --
    Process ("jpeg_baseline_biarritz.jpg");     --  Olympus camera
    Process ("jpeg_baseline_hifi.jpg");         --  Canon EOS 100D
    Process ("jpeg_progressive_lyon.jpg");      --  Rescaled by GIMP 2.10
    Process ("jpeg_progressive_walensee.jpg");  --  Rescaled by WhatsApp
    --
    Process ("png_interlaced_hifi.png");
    Process ("png_non_interlaced_hifi.png");
  end loop;
  --
  Put_Line ("=========================");
  Put_Line ("*** Statistics per image:");
  Show_Stats (image_stats);
  New_Line;
  Put_Line ("*** Statistics per image format:");
  Show_Stats (format_stats);
  New_Line;
  Put_Line ("*** Statistics per image format and subformat:");
  Show_Stats (format_subformat_stats);
  New_Line;
end Benchmark;
