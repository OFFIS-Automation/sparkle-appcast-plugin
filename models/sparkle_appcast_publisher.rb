require 'java'
require 'builder'
require 'pathname'
require 'fileutils'
require 'time'
require 'mime/types'

# Grab the good builds and the changelogs from the bad builds (so the good
# build that follows a bad build gets the bad build's changelog appended to
# its own).
def get_builds(latest_build)
    b=latest_build
    builds=[]
    begin
      builds.push({ :build => b, :changes => []}) if b.getResult.to_s == 'SUCCESS'
      builds.last[:changes] += b.getChangeSet.getItems.map { |c| c.getComment || c.getMsg  } if builds.last
    end while (b=b.getPreviousBuild) #getPreviousSuccessfulBuild
  builds
end

# The mime-types gem doesn't have x-apple-diskimage by default. Consider giving them a pull request.
MIME::Types.add(MIME::Type.from_hash('Content-Type' => 'application/x-apple-diskimage',
                                     'Content-Transfer-Encoding' => '8bit',
                                     'Extensions' => ['dmg']))

class Sparkle_appcastPublisher < Jenkins::Tasks::Publisher

  display_name "Publish Sparkle Appcast (RSS)"

  attr_reader :url_base, :output_directory, :author, :title, :description, :rss_filename, :message_filter, :use_markdown

  # Invoked with the form parameters when this extension point
  # is created from a configuration screen.
  def initialize(attrs = {})
    attrs.each { |k, v| v = nil if v == ""; instance_variable_set "@#{k}", v }
    @output_directory = Pathname.new(attrs["output_directory"]) if attrs["output_directory"]
  end

  ##
  # Runs before the build begins
  #
  # @param [Jenkins::Model::Build] build the build which will begin
  # @param [Jenkins::Model::Listener] listener the listener for this build.
  def prebuild(build, listener)
    # do any setup that needs to be done before this build runs.
  end

  ##
  # Runs the step over the given build and reports the progress to the listener.
  #
  # @param [Jenkins::Model::Build] build on which to run this step
  # @param [Jenkins::Launcher] launcher the launcher that can run code on the node running this build
  # @param [Jenkins::Model::Listener] listener the listener for this build.
  def perform(build_ruby, launcher, listener)
    build = build_ruby.native
    unless build.getResult.to_s == 'SUCCESS'
      listener.info "Not writing Appcast file for failed build."
      return
    end

    project_name = build.project.getDisplayName
    builds = get_builds(build)

    @rss_filename ||= project_name + ".rss"

    # Build link tree and keep track of URLs and filenames
    builds.each do |b|
      build = b[:build]
      version_dir = project_name + "-" + build.number.to_s
      raise "Can't build appcast #{@rss_filename}: Too many artifacts" if build.getArtifacts.size > 1
      first_artifact = build.getArtifacts.first.getFile
      b[:file] = @output_directory + version_dir + first_artifact.getName
      FileUtils.mkdir_p @output_directory + version_dir
      FileUtils.ln first_artifact.getAbsolutePath, b[:file]
      b[:url] = "#{@url_base}/#{version_dir}/#{first_artifact.getName}"
    end

    rss = Builder::XmlMarkup.new(:indent => 2)
    rss.instruct!
    rss_s = rss.rss("version"          => "2.0",
                    "xmlns:content"    => "http://purl.org/rss/1.0/modules/content/",
                    "xmlns:dc"         => "http://purl.org/dc/elements/1.1/",
                    "xmlns:sparkle"    => "http://www.andymatuschak.org/xml-namespaces/sparkle",
                    ) {
      rss.channel {
        rss.author      @author || "Jenkins"
        rss.updated     Time.now.to_s
        rss.link        "#{@url_base}/#{@rss_filename}"
        rss.title       @title || "#{project_name} Versions"
        rss.description @description || "#{project_name} Versions"

        builds.each do |b|
          rss.item {
            rss.link      b[:url]
            rss.title     "#{project_name} #{b[:build].number} Released"
            rss.updated   File.mtime(b[:file])
            rss.enclosure("url"    => b[:url],
                          "type"   => MIME::Types.type_for(b[:file].to_s).last || "application/octet-stream",
                          "length" => File.size(b[:file]),
                          "sparkle:version" => b[:build].number)
            rss.pubDate   File.ctime(b[:file])
            rss.dc(:date, File.ctime(b[:file]).iso8601)
            rss.description { rss.cdata! format_changelog(b[:changes]) }
          }
        end
      }
    }

    listener.info "Writing Appcast file \"#{@output_directory + @rss_filename}\"..."
    File.open(@output_directory + @rss_filename, "w") { |f| f.write(rss_s) }

  end

  def format_changelog(changes)
    # Stick all changelog messages together (adding newlines since the
    # message may not have one).  Then filter through them line by line
    # looking for lines that match the message_filter. The mesage filter
    # leaves blank lines around for the lines that don't match. This is so
    # the markdown conversion works better (otherwise you have to
    # consciously leave blank lines before or after everything in your
    # commmit message).  Change the '' to nil to make it just remove them
    # completely.
    changes_str = changes.map {|c| c+"\n" }.join('')
      .split("\n").map { |line| !@message_filter ? line :
                                line.start_with?(@message_filter) ? line[@message_filter.length..-1] : '' }.compact
      .join("\n")

    return changes_str unless @use_markdown

    # Not sure this is right. Can I get to the jenkins plugin that's already
    # been inited? This one doesn't seem to care that I pass in empty arrays...
    pd = org.jenkins_ci.plugins.pegdown_formatter.PegDownFormatter.new([],[])
    out = java.io.StringWriter.new
    pd.translate(changes_str, out)
    out.toString
  end

end
