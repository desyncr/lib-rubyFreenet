require 'stringio'

class MessageTests < Test::Unit::TestCase
  # Check that a message is written in the correct format with an identifier
  def test_write_message
    m = Freenet::FCP::Message.new('TestMessage', nil, 'Item1' => 'Item1Value', 'Item2' => 'Item2Value')
    s = StringIO.new
    m.write(s)
    s.rewind
    assert_equal('TestMessage', s.readline.strip)
    3.times do
      assert(['Item1=Item1Value', 'Item2=Item2Value', "Identifier=#{m.identifier}"].include? s.readline.strip)
    end
    assert_equal('EndMessage',s.readline.strip)
  end
  
  # Check that a message writes data properly
  def test_write_data
  end
end