#-------------------------------------------------------------------------------
#
# Thomas Thomassen
# thomas[at]thomthom[dot]net
#
#-------------------------------------------------------------------------------

require 'sketchup.rb'
require 'TT_Lib2/core.rb'

TT::Lib.compatible?('2.6.0', 'TT Shadow Catcher')

#-------------------------------------------------------------------------------


module TT::Plugins::ShadowCatcher

=begin

http://stackoverflow.com/a/2818881/486990


Imagine the projection onto a plane as a "view" of the model (i.e. the direction
of projection is the line of sight, and the projection is what you see). In that
case, the borders of the polygons you want to compute correspond to the
silhouette of the model.

The silhouette, in turn, is a set of edges in the model. For each edge in the
silhouette, the adjacent faces will have normals that either point away from the
plane or toward the plane. You can check this be taking the dot product of the
face normal with the plane normal -- look for edges whose adjacent face normals
have dot products of opposite signs with the projection direction.

Once you have found all the silhouette edges you can join them together into the
boundaries of the desired polygons.

Generally, you can find more about silhouette detection and extraction by
googling terms like mesh silouette finding detection. 

=end
  
  ### CONSTANTS ### ------------------------------------------------------------
  
  # Plugin information
  PLUGIN_ID       = 'TT_ShadowCatcher'.freeze
  PLUGIN_NAME     = 'Shadow Catcher'.freeze
  PLUGIN_VERSION  = TT::Version.new( 1,0,0 ).freeze
  
  SHADOWS_MATERIAL_NAME  = '02 - Shadows'.freeze
  SHADOWS_MATERIAL_COLOR = Sketchup::Color.new( 255, 0, 0 )
  SHADOWS_MATERIAL_ALPHA = 0.5
  
  
  ### MENU & TOOLBARS ### ------------------------------------------------------
  
  unless file_loaded?( __FILE__ )
    # Menus
    menu = TT.menu( 'Plugins' )
    menu.add_item( 'Catch Shadows' ) { self.catch_shadows }
  end 
  
  
  ### LIB FREDO UPDATER ### ----------------------------------------------------
  
  def self.register_plugin_for_LibFredo6
    {   
      :name => PLUGIN_NAME,
      :author => 'thomthom',
      :version => PLUGIN_VERSION.to_s,
      :date => '27 Sep 12',
      :description => 'Catches shadows on selected face.',
      :link_info => 'http://forums.sketchucation.com/viewtopic.php?f=0&t=0'
    }
  end
  
  
  ### MAIN SCRIPT ### ----------------------------------------------------------

  
  # Projects shadows from instances in the current context onto selected face.
  # 
  # Shadow casting instances can be limited by selecting the instances that
  # should cast shadows.
  # 
  # @since 1.0.0
  def self.catch_shadows
    model = Sketchup.active_model
    selection = model.selection
    context = model.active_entities
    direction = model.shadow_info['SunDirection'].reverse
    
    # Validate User Input
    # Ensure there is one, and only one, face that receives shadows in the 
    # selection.
    faces = selection.select { |e|
      e.is_a?( Sketchup::Face ) &&
      e.receives_shadows?
    }
    instances = self.select_visible_instances( selection.to_a - faces )
    if faces.empty?
      UI.messagebox( 'There must be a face receiving shadows in the selection.' )
      return nil
    elsif faces.size > 1
      UI.messagebox( 'There can be only one face receiving shadows in the selection.' )
      return nil
    end
    # If no instances are selected then all instances in the current context is
    # processed.
    # 
    # (?) Detect and ignore previously processed shadow groups?
    if instances.empty?
      instances = self.select_visible_instances( model.active_entities )
    end
    # Ensure there is something to cast shadows.
    if instances.empty?
      UI.messagebox( 'There is no geometry to cast shadow.' )
      return nil
    end
    
    model.start_operation( 'Catch Shadows' )

    target_face = faces.first             # Face to catch shadows for.
    instance_shadows = context.add_group  # Group containing generated shadows.
    for instance in instances
      # Cast shadows from the instance onto the plane of the target face.
      definition = TT::Instance.definition( instance )
      entities = definition.entities
      transformation = instance.transformation
      shadows, ground_area = self.shadows_from_entities(
        target_face, entities, transformation, direction, instance_shadows.entities
      )
      # Trim shadows to the target face.
      trim_group = self.create_trim_group( target_face, context )
      trim_group_definition = TT::Instance.definition( trim_group )
      for shadow in shadows.entities
        self.trim_to_face( target_face, shadow.entities, transformation, trim_group_definition )
      end
      trim_group.erase!
      # Merge shadows from each mesh group into one.
      self.merge_instances( shadows.entities )
    end
    # Merge shadows from all instances into one.
    self.merge_instances( instance_shadows.entities )
    # Organize shadow group into a layer with a descriptive name.
    instance_shadows.layer = self.get_shadow_layer
    instance_shadows.name = "Shadows: #{self.get_formatted_shadow_time}"
    # Output area data.
    self.calculate_shadow_statistics( target_face, instance_shadows.entities, ground_area )
    
    model.commit_operation
    
  end
  
  
  # Intersect doesn't always split the mesh like you would expect.
  # 
  # A +
  #   |\
  #   | \  
  # B +--+--+ C
  #      ^
  #      D
  # 
  # In this polygon ( ABCD ) vertex D overlaps edge BC, but intersect doesn't
  # split it. BC and CD both connects to face ABCD even though they overlap.
  # 
  # This method creates a set of zero length edges at each vertex in a temp
  # group which will cause the edges to properly split when the temp group is
  # exploded.
  # 
  # @param [Sketchup::Entities] entities
  # 
  # @return [Nil]
  def self.split_at_vertices( entities )
    edges = entities.select { |e| e.is_a?( Sketchup::Edge ) }
    vertices = edges.map { |edge| edge.vertices }
    vertices.flatten!
    vertices.uniq!
    vector = Geom::Vector3d.new( 0, 0, 10.m )
    end_vertices = []
    temp_group = entities.add_group
    for vertex in vertices
      pt1 = vertex.position
      pt2 = pt1.offset( vector )
      temp_edge = temp_group.entities.add_line( pt1, pt2 )
      end_vertices << temp_edge.end
    end
    temp_group.entities.transform_by_vectors( end_vertices, [vector.reverse] * end_vertices.size )
    temp_group.explode
    nil
  end
  
  
  def self.select_visible_instances( entities )
    entities.select { |e|
      TT::Instance.is?( e ) &&
      e.casts_shadows? &&
      ( e.visible? && e.layer.visible? )
    }
  end
  
  
  def self.get_formatted_shadow_time
    model = Sketchup.active_model
    time = model.shadow_info['ShadowTime'].getutc
    time.strftime( '%H:%M - %d %B' )
  end
  
  
  def self.get_shadow_layer
    model = Sketchup.active_model
    layername = "02 - #{self.get_formatted_shadow_time}"
    unless layer = model.layers[ layername ]
      layer = Sketchup.active_model.layers.add( layername )
      layer.page_behavior = LAYER_IS_HIDDEN_ON_NEW_PAGES
      model.pages.each { |page|
        next if model.pages.selected_page == page
        page.set_visibility( layer, false )
      }
    end
    layer
  end
  
  
  def self.calculate_shadow_statistics( ground_face, shadow_entities, footprint_area )
    model = ground_face.model
    entities = ground_face.parent.entities
    
    # Calculate
    site_area   = ground_face.area            # The whole site
    ground_area = site_area - footprint_area  # Site without building footprints
    shadow_area = total_area( shadow_entities )
    sun_area    = ground_area - shadow_area
    
    footprint_percent = ( footprint_area / site_area ) * 100.0
    ground_percent    = ( ground_area / site_area ) * 100.0
    shadow_percent    = ( shadow_area / ground_area ) * 100.0
    sun_percent       = ( sun_area / ground_area ) * 100.0
    
    # Format
    site_area      = Sketchup.format_area( site_area )
    ground_area    = Sketchup.format_area( ground_area )
    footprint_area = Sketchup.format_area( footprint_area )
    shadow_area    = Sketchup.format_area( shadow_area )
    sun_area       = Sketchup.format_area( sun_area )
    
    footprint_percent = sprintf( "%.2f", footprint_percent )
    ground_percent    = sprintf( "%.2f", ground_percent )
    shadow_percent    = sprintf( "%.2f", shadow_percent )
    sun_percent       = sprintf( "%.2f", sun_percent )
    
    # Output
    output = <<-EOT.gsub(/^ {6}/, '')
              Site Area: #{site_area}
              
         Ground Area: #{ground_area} ( #{ground_percent}% of Site )
      Footprint Area: #{footprint_area} ( #{footprint_percent}% of Site )
      
               Sun Area: #{sun_area} (#{sun_percent}% of Ground )
        Shadow Area: #{shadow_area} (#{shadow_percent}% of Ground )
    EOT
    while model.active_path
      # If a note is added while not in root context it will shift about when
      # oriting the view.
      model.close_active
    end
    model.selection.clear
    note = model.add_note( output, 0.4, 0.1 )
    note.layer = self.get_shadow_layer
  end
  
  
  def self.total_area( entities )
    area = 0.0
    for face in entities
      next unless face.is_a?( Sketchup::Face )
      area += face.area
    end
    area
  end
  
  
  def self.merge_instances( entities )
    for entity in entities.to_a
      next unless TT::Instance.is?( entity )
      entity.explode
    end
    self.remove_inner_faces( entities )
  end
  
  
  def self.remove_inner_faces( entities )
    inner_edges = []
    for entity in entities
      next unless entity.is_a?( Sketchup::Edge )
      inner_edges << entity if entity.faces.size != 1
    end
    entities.erase_entities( inner_edges )
  end
  
  
  def self.create_trim_group( face, entities )
    group = entities.add_group
    for edge in face.edges
      points = edge.vertices.map { |v| v.position }
      group.entities.add_line( *points )
    end
    group
  end
  
  
  def self.mid_point( edge )
    pt1, pt2 = edge.vertices.map { |v| v.position }
    mid = Geom.linear_combination( 0.5, pt1, 0.5, pt2 )
  end
  
  
  def self.trim_to_face( face, entities, transformation, trim_group )
    g = entities.add_instance( trim_group, transformation.inverse )
    # Intersect with trim edges.
    tr0 = Geom::Transformation.new
    entities.intersect_with(
      false,    # (intersection lines will be put inside of groups and components within this entities object).
      tr0,      # The transformation for this entities object.
      entities, # The entities object where you want the intersection lines to appear.
      tr0,      # The transformation for entities1. 
      false,    # true if you want hidden geometry in this entities object to be used in the intersection.
      g         # A single entity, or an array of entities.
    )
    g.erase!
    # Remove geometry that is outside the target.
    outside = []
    for edge in entities.to_a
      next unless edge.is_a?( Sketchup::Edge )
      pt = self.mid_point( edge )
      
      result = face.classify_point( pt.transform(transformation) )
      error = result == Sketchup::Face::PointUnknown
      inside = result <= Sketchup::Face::PointOnEdge 
      
      #entities.add_cpoint( pt )
      #entities.add_cpoint( pt.offset( Z_AXIS, 10.m ) ) if inside
      #entities.add_cline( pt,  pt.offset( Z_AXIS, 10.m ) )
      
      next if inside
      
      outside << edge
    end
    entities.erase_entities( outside )
  end
  
  
  def self.get_shadow_material
    model = Sketchup.active_model
    m = model.materials[ SHADOWS_MATERIAL_NAME ]
    unless m
      m = model.materials.add( SHADOWS_MATERIAL_NAME )
      m.color = SHADOWS_MATERIAL_COLOR
      m.alpha = SHADOWS_MATERIAL_ALPHA
    end
    m
  end
  
  
  def self.shadows_from_entities( target_face, entities, transformation, direction, context )    
    # Target
    # Transform target plane and sun direction into the coordinates of the
    # instance - this avoids transforming every 3D point in this mesh to the
    # parent and should be faster.
    to_local = transformation.inverse
    target_normal = target_face.normal.transform( to_local )
    plane = [target_face.vertices.first.position, target_face.normal]
    target_plane = plane.map { |x| x.transform( to_local ) }
    direction = direction.transform( to_local )

    # Ground Polygons
    # These are the faces we cast shaodows from on the target plane. These are
    # used later to remove their footprint.
    ground_area = 0.0
    ground_polygons = entities.select { |e|
      if  e.is_a?( Sketchup::Face ) &&
          e.normal.parallel?( target_normal ) &&
          e.vertices.first.position.on_plane?( target_plane )
        ground_area += e.area
        true
      else
        false
      end
    }.map { |face| face.outer_loop.vertices.map { |v| v.position } }

    # Group Meshes
    # Each set of connected meshes are processed by them self to avoid
    # unpredictable behaviour with overlapping shadows,
    meshes = []
    stack = entities.select { |e| e.respond_to?( :all_connected ) }
    until stack.empty?
      meshes << stack.first.all_connected
      stack -= meshes.last
    end

    # Output Groups
    # Destination groups with the faces representing the shadows.
    outline_group = context.add_group
    outline_group.transform!( transformation )
    #outline_group.material = 'red'
    outline = outline_group.entities

    shadows_group = context.add_group
    shadows_group.transform!( transformation )
    shadows_group.material = self.get_shadow_material
    shadows = shadows_group.entities

    # Project Shadows
    # Find the edges outlined from the sun's position and project them to the
    # target plane.
    Sketchup.status_text = 'Projecting outlines...'
    for mesh in meshes
      shadow_group = shadows.add_group
      shadow = shadow_group.entities
      for edge in mesh
        next unless edge.is_a?( Sketchup::Edge )
        shadow_faces = edge.faces.select { |face| face.casts_shadows? }
        next if shadow_faces.empty?
        if shadow_faces.size > 1
          dots = shadow_faces.map { |face| direction % face.normal < 0 }
          next if dots.all? { |dot| dot == dots.first }
        end
        # Visualize sun outline.
        outline.add_line( edge.vertices.map { |v| v.position } )
        # Project outlines to target plane.
        rays = edge.vertices.map { |v| [ v.position, direction ] }
        points = rays.map { |ray| Geom.intersect_line_plane( ray, target_plane ) }
        # <debug>
        # for i in (0...rays.size)
        #   shadow.add_cline( rays[i][0], points[i] )
        #   shadow.add_cpoint( rays[i][0] )
        #   shadow.add_cpoint( points[i] )
        # end
        # </debug>
        shadow.add_line( points )
      end
    end

    # Create shadow faces.
    Sketchup.status_text = 'Finding faces...'
    for shadow in shadows
      se = shadow.entities
      # Intersect edges as the outline might be crossing itself.
      tr = Geom::Transformation.new
      se.intersect_with( false, tr, se, tr, true, se.to_a )
      # Find all possible faces.
      for edge in shadow.entities.to_a
        next unless edge.is_a?( Sketchup::Edge )
        edge.find_faces
      end
      # Clean up inner edges.
      inner_edges = shadow.entities.select { |e|
        e.is_a?( Sketchup::Edge ) && e.faces.size > 1
      }
      shadow.entities.erase_entities( inner_edges )
    end

    # Remove ground polygons.
    Sketchup.status_text = 'Removing ground polygons...'
    for shadow in shadows
      se = shadow.entities
      tr = Geom::Transformation.new
      for polygon in ground_polygons       
        # Create a face representing the ground polygon and erase it.
        face = se.add_face( polygon )
        # If edges of the new face overlaps the shadow face it might not split
        # at vertex intersections. Manually trigger merges for this.
        # Group & Explore or Intersection does not work.
        self.split_at_vertices( se )
        # (?) Can ´face´ be invalid at this point due to the merge?
        edges = face.edges
        face.erase!
        
        # Intersect and remove edges with midpoint inside the polygon.
        se.intersect_with( false, tr, se, tr, true, edges )
        redundant_edges = []
        for edge in se.to_a
          next unless edge.is_a?( Sketchup::Edge )
          # Remove stray edges
          if edge.faces.empty?
            redundant_edges << edge
            next
          end
          # Remove edges inside ground polygon.
          pt1, pt2 = edge.vertices.map { |v| v.position }
          mid = Geom.linear_combination( 0.5, pt1, 0.5, pt2 )
          next unless Geom.point_in_polygon_2D( mid, polygon, false )
          redundant_edges << edge
        end
        se.erase_entities( redundant_edges )
      end
      # Clean up more. Some times there are strange overlaps that intersect
      # doesn't properly split.
      self.split_at_vertices( se )
      redundant_edges = []
      for edge in se.to_a
        next unless edge.is_a?( Sketchup::Edge )
        next if edge.faces.size == 1
        redundant_edges << edge
      end
      se.erase_entities( redundant_edges )
    end # for
    
    #outline_group.material = 'red'
    outline_group.erase!
    
    [ shadows_group, ground_area ]
  end

  ### DEBUG ### ----------------------------------------------------------------
  
  # @note Debug method to reload the plugin.
  #
  # @example
  #   TT::Plugins::ShadowCatcher.reload
  #
  # @since 1.0.0
  def self.reload( tt_lib = false )
    original_verbose = $VERBOSE
    $VERBOSE = nil
    load __FILE__
  ensure
    $VERBOSE = original_verbose
  end

end # module

#-------------------------------------------------------------------------------

file_loaded( __FILE__ )

#-------------------------------------------------------------------------------