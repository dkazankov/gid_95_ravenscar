with GID,
     Comp_Img_Fct,
     Fast_IO;

with Ada.Real_Time,
     Ada.Characters.Handling,
     Ada.Containers.Indefinite_Ordered_Maps,
     Ada.Containers.Vectors,
     Ada.Directories,
     Ada.Environment_Variables,
     Ada.Streams.Stream_IO,
     Ada.Strings.Fixed,
     Ada.Text_IO,
     Ada.Unchecked_Deallocation;

with Interfaces.C;

procedure Benchmark is

  use Ada.Real_Time, Ada.Characters.Handling, Ada.Streams.Stream_IO,
      Ada.Strings.Fixed, Ada.Text_IO, Interfaces;

  procedure Blurb is
  begin
    Put_Line ("Benchmark for the GID (Generic Image Decoder) package");
    Put_Line ("Package version " & GID.version & " dated " & GID.reference);
    Put_Line ("URL: " & GID.web);
    New_Line;
    Put_Line ("Benchmark must be built by GNAT in the ""Fast_unchecked"" mode.");
    New_Line;
    Put_Line ("GID is compared against results of ImageMagick ( https://imagemagick.org/ ).");
    Put_Line ("The executable ""magick[.exe]"" needs to be visible on the path.");
    New_Line;
    Put_Line ("Syntax:");
    Put_Line ("benchmark");
    New_Line;
    Put_Line ("In order to save your SDD / Hard Disk and to minimize file transaction times,");
    Put_Line ("it is recommended to copy the images (originally in ./test/img) to a RAM Disk");
    Put_Line ("and run the program there. A subdirectory ""img"" (relative to the current");
    Put_Line ("directory) is expected by the program for reading the test images.");
    Put_Line ("This test might take 10 minutes or more. Be patient!");
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
     next_frame : out Duration)
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
      so_far : constant Natural := percents / 20;
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
    package U8_Fast_IO is new Fast_IO (Unsigned_8, Byte_Array);
  begin
    Create (f, Out_File, name);
    --  PPM Header:
    String'Write
      (Stream (f),
       "P6 " & GID.Pixel_Width (i)'Image & GID.Pixel_Height (i)'Image &
       " 255" & ASCII.LF);
    --  PPM raw RGB image:
    U8_Fast_IO.Write (Stream (f).all, img_buf.all);
    Close (f);
  end Dump_PPM;

  ---------------------------
  --  Statistics database  --
  ---------------------------

  package Name_Maps is new Ada.Containers.Indefinite_Ordered_Maps
    (Key_Type     => String,
     Element_Type => Positive);

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
  format_subformat_stats,
  global_stats : Name_Maps.Map;

  dur_external_call : Duration;

  function GNAT_Sys (Arg : Interfaces.C.char_array) return Interfaces.C.int;
  pragma Import (C, GNAT_Sys, "system");

  procedure Sys (Command : String; Result : out Integer) is
    --  https://rosettacode.org/wiki/Execute_a_system_command#Ada
  begin
    Result := Integer (GNAT_Sys (Interfaces.C.To_C (Command)));
  end Sys;

  procedure Compute_Penalty_for_External_Calls (iterations : Integer) is
    use Ada.Environment_Variables;
    T0, T1 : Time;
    res : Integer;
    --  The command does nothing useful; we just want to time the call.
    command : constant String :=
      "magick -version >" &
      (if Value ("OS") = "Windows_NT" then "nul" else "/dev/null");
  begin
    dur_external_call := Duration'Last;
    for iter in 1 .. iterations loop
      T0 := Clock;
      Sys (command, res);
      if res /= 0 then
        Put_Line ("Error calling magick!");
        raise Program_Error;
      end if;
      T1 := Clock;
      dur_external_call := Duration'Min (dur_external_call, To_Duration (T1 - T0));
      delay until Clock + To_Time_Span (0.002 / (1 + iter mod 37));
      --  ^ Add some randomness in thread's scheduling
    end loop;
  end Compute_Penalty_for_External_Calls;

  package DIO is new Fixed_IO (Duration);
  package FIO is new Float_IO (Float);

  procedure Process (name : String; is_first_iteration : Boolean) is
    f : Ada.Streams.Stream_IO.File_Type;
    i : GID.Image_Descriptor;
    up_name : constant String := To_Upper (name);
    next_frame : Duration := 0.0;

    use Ada.Directories;
    res : Integer;
    T0, T1, T2 : Time;
    dur_gid, dur_magick : Duration;

    gid_name    : constant String := name & "_gid.ppm";
    magick_name : constant String := name & "_magick.ppm";

    img_dir : constant String := "img/";

    rel_name        : constant String := img_dir & name;
    rel_gid_name    : constant String := img_dir & gid_name;
    rel_magick_name : constant String := img_dir & magick_name;

    dist : Long_Float;

    procedure Feed_Stat (stat_map : in out Name_Maps.Map; stat_name : String) is
      procedure Feed_To (the_row : in out Stats_Row) is
      begin
        the_row.cumulative_duration_gid   := the_row.cumulative_duration_gid + dur_gid;
        the_row.cumulative_duration_other := the_row.cumulative_duration_other + dur_magick;
        if is_first_iteration then
          the_row.difference_score := the_row.difference_score + dist;
          the_row.occ_per_category := the_row.occ_per_category + 1;
        end if;
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
    Open (f, In_File, rel_name);
    Put (name & (42 - name'Length) * ' ');
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
    Dump_PPM (rel_gid_name, i);
    --
    Close (f);
    T1 := Clock;
    --
    --  Call the other tool.
    --
    Sys ("magick " & rel_name & ' ' & rel_magick_name, res);
    if res /= 0 then
      Put_Line ("Error calling magick!");
      raise Program_Error;
    end if;
    T2 := Clock;
    dur_gid    := To_Duration (T1 - T0);
    dur_magick := To_Duration (T2 - T1);
    Put (" GID: ");
    DIO.Put (dur_gid, 0, 3);
    Put ("s, IM: ");
    DIO.Put (dur_magick, 0, 3);
    if is_first_iteration then
      Put ("s; col. diff.: ");
      dist := Comp_Img_Fct (rel_gid_name, rel_magick_name, False);
      FIO.Put (Float (dist), 0, 4, 0);
    else
      Put ('s');
    end if;
    New_Line;
    --
    Feed_Stat (image_stats, name);
    Feed_Stat (global_stats, "All images");
    Feed_Stat (format_stats, GID.Format (i)'Image);
    Feed_Stat
      (format_subformat_stats,
       GID.Format (i)'Image & ' ' &
       GID.Detailed_Format (i) &
       " Subformat" & GID.Subformat (i)'Image);
    --
    --  Cleanup
    --
    Delete_File (rel_gid_name);
    Delete_File (rel_magick_name);
  end Process;

  iterations : constant := 100;

  procedure Show_Stats (category_map : Name_Maps.Map) is

    procedure Show_Row_Details (row : Stats_Row) is
      denom : constant Integer := iterations * row.occ_per_category;
      dur_gid, dur_magick, dur_magick_less_ext_call : Duration;
    begin
      Put_Line
        ("    Images in this category  . . . . . . . . . . . . . . . . . :" &
         row.occ_per_category'Image);
      Put_Line
        ("    Average color difference score . . . . . . . . . . . . . . :" &
         Float'Image
           (Float (row.difference_score) / Float (row.occ_per_category)));
      dur_gid := row.cumulative_duration_gid / denom;
      Put_Line
        ("    Average duration GID [1] . . . . . . . . . . . . . . . . . :" &
         dur_gid'Image);
      dur_magick := row.cumulative_duration_other / denom;
      Put_Line
        ("    Average duration ImageMagick (external call) . . . . . . . :" &
         dur_magick'Image);
      dur_magick_less_ext_call := dur_magick - dur_external_call;
      Put_Line
        ("    Average duration ImageMagick (as if internally called) [2] :" &
         dur_magick_less_ext_call'Image);
      Put_Line
        ("    [1]  vs. [2]: " &
         (if dur_gid < dur_magick_less_ext_call then
            "GID is" &
            Float'Image (Float (dur_magick_less_ext_call) / Float (dur_gid))
          else
            "ImageMagick (as if internally called) is" &
            Float'Image (Float (dur_gid) / Float (dur_magick_less_ext_call))) &
         " times faster");
      New_Line;
    end Show_Row_Details;

  begin
    New_Line;
    for curs in category_map.Iterate loop
      Put_Line (Name_Maps.Key (curs));
      Show_Row_Details (stats_table (Name_Maps.Element (curs)));
    end loop;
  end Show_Stats;

  T0, T1 : Time;

begin
  T0 := Clock;
  Blurb;

  Compute_Penalty_for_External_Calls (400);

  for iter in 1 .. iterations loop
    Put_Line ("---------------------------- Iteration" & iter'Image);
    Put_Line (Current_Error, iter'Image & " /" & iterations'Image);
    Process ("gif_interlaced_bush.gif", iter = 1);
    Process ("gif_non_interlaced_bush.gif", iter = 1);
    Process ("gif_sparse_10k_x_10k.gif", iter = 1);
    --
    Process ("jpeg_baseline_biarritz.jpg", iter = 1);      --  Olympus camera
    Process ("jpeg_baseline_tirol.jpg", iter = 1);         --  Nokia 301, panoramic
    Process ("jpeg_baseline_neuchatel_1.jpg", iter = 1);   --  Nokia 301, panoramic
    Process ("jpeg_baseline_neuchatel_2.jpg", iter = 1);   --  Nokia 301, panoramic
    Process ("jpeg_baseline_horgenberg.jpg", iter = 1);    --  Nokia 301, panoramic
    Process ("jpeg_baseline_maschgenkamm.jpg", iter = 1);  --  Nokia 301, panoramic
    Process ("jpeg_baseline_pfannenstiel.jpg", iter = 1);  --  Nokia 301, panoramic
    Process ("jpeg_baseline_saint_malo.jpg", iter = 1);    --  Nokia 301, panoramic
    Process ("jpeg_baseline_waedenswil.jpg", iter = 1);    --  Nokia 301, panoramic
    Process ("jpeg_baseline_sparse_10k_x_10k.jpg", iter = 1);

    Process ("jpeg_baseline_bush.jpg", iter = 1);                 --  Canon EOS 100D, Size S1
    Process ("jpeg_baseline_bush_25_pct_quality.jpg", iter = 1);  --  GIMP, 25% quality
    --
    Process ("jpeg_progressive_lyon.jpg", iter = 1);                 --  Rescaled by GIMP 2.10
    Process ("jpeg_progressive_walensee.jpg", iter = 1);             --  Rescaled by WhatsApp
    Process ("jpeg_progressive_lyon_25_pct_quality.jpg", iter = 1);  --  GIMP, 25% quality
    Process ("jpeg_progressive_sparse_10k_x_10k.jpg", iter = 1);
    --
    Process ("png_interlaced_bush.png", iter = 1);
    Process ("png_non_interlaced_bush.png", iter = 1);
    Process ("png_pixellized_lisboa.png", iter = 1);
    Process ("png_sparse_10k_x_10k.png", iter = 1);
  end loop;
  --
  Put_Line ("==============================================================");
  Put_Line ("Measured time for empty external call" & dur_external_call'Image);
  New_Line;
  Put_Line ("*** Statistics per image:");
  Show_Stats (image_stats);
  New_Line;
  Put_Line ("*** Statistics per image format and subformat:");
  Show_Stats (format_subformat_stats);
  New_Line;
  Put_Line ("*** Statistics per image format:");
  Show_Stats (format_stats);
  New_Line;
  Put_Line ("*** Statistics for all images:");
  Show_Stats (global_stats);
  New_Line;

  T1 := Clock;
  Put_Line
    ("Total benchmark time:" & Duration'Image (To_Duration ((T1 - T0) / 60)) & " minutes.");
end Benchmark;
